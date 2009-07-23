class CassandraClient
  include Helper  
  class AccessError < StandardError; end
  
  MAX_INT = 2**31 - 1
  
  module Consistency
    # FIXME Assumes you have 3 replicas
    NONE = ZERO = 0
    WEAK = ONE = 1
    STRONG = QUORUM = 2
    PERFECT = ALL = 3
  end
  
  attr_reader :keyspace, :host, :port, :serializer, :transport, :client, :schema

  # Instantiate a new CassandraClient and open the connection.
  def initialize(keyspace, host = '127.0.0.1', port = 9160, serializer = CassandraClient::Serialization::JSON)
    @keyspace = keyspace
    @host = host
    @port = port
    @serializer = serializer

    @transport = Thrift::BufferedTransport.new(Thrift::Socket.new(@host, @port))
    @transport.open    
    @client = Cassandra::SafeClient.new(
      Cassandra::Client.new(Thrift::BinaryProtocol.new(@transport)), 
      @transport)

    keyspaces = @client.getStringListProperty("tables")
    unless keyspaces.include?(@keyspace)
      raise AccessError, "Keyspace #{@keyspace.inspect} not found. Available: #{keyspaces.inspect}"
    end
        
    @schema = @client.describeTable(@keyspace)
  end
    
  def inspect
    "#<CassandraClient:#{object_id}, @keyspace=#{keyspace.inspect}, @schema={#{
      schema.map {|name, hash| ":#{name} => #{hash['type'].inspect}"}.join(', ')
    }}, @host=#{host.inspect}, @port=#{port}, @serializer=#{serializer.name}>"
  end

  ## Write
  
  # Insert a row for a key. Pass a flat hash for a regular column family, and 
  # a nested hash for a super column family.
  def insert(column_family, key, hash, consistency = Consistency::WEAK, timestamp = now)
    mutation = if is_super(column_family) 
      BatchMutationSuper.new(:key => key, :cfmap => {column_family.to_s => hash_to_super_columns(hash, timestamp)})
    else
      BatchMutation.new(:key => key, :cfmap => {column_family.to_s => hash_to_columns(hash, timestamp)})      
    end
    # FIXME Batched operations discard the consistency argument
    @batch ? @batch << mutation : _insert(mutation, consistency)
  end
  
  private
  
  def _insert(mutation, consistency = Consistency::WEAK)
    case mutation
    when BatchMutationSuper then @client.batch_insert_super_column(@keyspace, mutation, consistency)    
    when BatchMutation then @client.batch_insert(@keyspace, mutation, consistency)
    end
  end  
  
  public
  
  ## Delete
  
  # Remove the element at the column_family:key:super_column:column 
  # path you request.
  def remove(column_family, key, super_column = nil, column = nil, consistency = Consistency::WEAK, timestamp = now)
    args = [column_family, key, super_column, column, consistency, timestamp]
    @batch ? @batch << args : _remove(*args)
  end
  
  private 
  
  def _remove(column_family, key, super_column, column, consistency, timestamp)
     super_column, column = column, super_column unless is_super(column_family)
    @client.remove(@keyspace, key,
      ColumnPathOrParent.new(:column_family => column_family.to_s, :super_column => super_column, :column => column), 
      timestamp, consistency)
  end
   
  public
  
  # Remove all rows in the column family you request.
  def clear_column_family!(column_family)
    # Does not support consistency argument
    get_key_range(column_family).each do |key| 
      remove(column_family, key)
    end
  end

  # Remove all rows in the keyspace
  def clear_keyspace!
    # Does not support consistency argument
    @schema.keys.each do |column_family|
      clear_column_family!(column_family)
    end
  end
  
  ## Read

  # Count the elements at the column_family:key:super_column path you 
  # request.
  def count_columns(column_family, key, super_column = nil, consistency = Consistency::WEAK)
    @client.get_column_count(@keyspace, key, 
      ColumnParent.new(:column_family => column_family.to_s, :super_column => super_column)
    )
  end
  
  # Multi-key version of CassandraClient#count_columns.
  def multi_count_columns(column_family, keys, super_column = nil, consistency = Consistency::WEAK)
    OrderedHash[*keys.map do |key|   
      [key, count_columns(column_family, key, super_column)]
    end._flatten_once]
  end  
  
  # Return a list of single values for the elements at the
  # column_family:key:super_column:column path you request.
  def get_columns(column_family, key, super_columns, columns = nil, consistency = Consistency::WEAK)
    super_columns, columns = columns, super_columns unless columns
    result = if is_super(column_family) && !super_columns 
      columns_to_hash(@client.get_slice_super_by_names(@keyspace, key, column_family.to_s, columns))
    else
      columns_to_hash(@client.get_slice_by_names(@keyspace, key, 
        ColumnParent.new(:column_family => column_family.to_s, :super_column => super_columns), columns))
    end    
    columns.map { |name| result[name] }
  end

  # Multi-key version of CassandraClient#get_columns.
  def multi_get_columns(column_family, keys, super_columns, columns = nil, consistency = Consistency::WEAK)
    OrderedHash[*keys.map do |key| 
      [key, get_columns(column_family, key, super_columns, columns, consistency)]
    end._flatten_once]
  end
        
  # Return a hash (actually, a CassandraClient::OrderedHash) or a single value 
  # representing the element at the column_family:key:super_column:column 
  # path you request.
  def get(column_family, key, super_column = nil, column = nil, limit = 100, consistency = Consistency::WEAK)
    # You have got to be kidding
    if is_super(column_family)
      if column
        load(@client.get_column(@keyspace, key,  ColumnPath.new(:column_family => column_family.to_s, :super_column => super_column, :column => column)).value)
      elsif super_column
        columns_to_hash(@client.get_super_column(@keyspace, key,  SuperColumnPath.new(:column_family => column_family.to_s, :super_column => super_column)).columns)
      else
        # FIXME bug
        columns_to_hash(@client.get_slice_super(@keyspace, key, column_family.to_s, '', '', -1, limit))
      end
    else
      if super_column
        load(@client.get_column(@keyspace, key, ColumnPath.new(:column_family => column_family.to_s, :column => super_column)).value)
      elsif is_sorted_by_time(column_family)
        result = columns_to_hash(@client.get_columns_since(@keyspace, key, ColumnParent.new(:column_family => column_family.to_s), 0))

        # FIXME Hack until get_slice on a time-sorted column family works again
        result = OrderedHash[*result.to_a[0, limit]._flatten_once]
        result
      else
        columns_to_hash(@client.get_slice(@keyspace, key, ColumnParent.new(:column_family => column_family.to_s), '', '', -1, limit))
      end 
    end
  rescue NotFoundException
    is_super(column_family) && !column ? OrderedHash.new : nil
  end
  
  # Multi-key version of CassandraClient#get.
  def multi_get(column_family, keys, super_column = nil, column = nil, limit = 100, consistency = Consistency::WEAK)
    OrderedHash[*keys.map do |key| 
      [key, get(column_family, key, super_column, column, limit, consistency)]
    end._flatten_once]
  end
  
  # FIXME
  # def exists?
  # end
  
  # FIXME
  # def get_recent(column_family, key, super_column = nil, column = nil, timestamp = 0)
  # end

  # Return a list of keys in the column_family you request. Requires the
  # table to be partitioned with OrderPreservingHash.
  def get_key_range(column_family, key_range = ''..'', limit = 100, consistency = Consistency::WEAK)      
    @client.get_key_range(@keyspace, column_family.to_s, key_range.begin, key_range.end, limit)
  end
  
  # Count all rows in the column_family you request. Requires the table 
  # to be partitioned with OrderPreservingHash.
  def count(column_family, key_range = ''..'', limit = MAX_INT, consistency = Consistency::WEAK)
    get_key_range(column_family, key_range, limit, consistency).size
  end
  
  def batch
    @batch = []
    yield    
    compact_mutations!
    dispatch_mutations!    
    @batch = nil
  end
  
  private

  def compact_mutations!
    compact_batch = []
    mutations = {}   

    @batch << nil # Close it
    @batch.each do |m|
      case m
      when Array, nil
        # Flush compacted mutations
        compact_batch.concat(mutations.values.map {|x| x.values}.flatten)
        mutations = {}
        # Insert delete operation
        compact_batch << m 
      else # BatchMutation, BatchMutationSuper
        # Do a nested hash merge
        if mutation_class = mutations[m.class]
          if mutation = mutation_class[m.key]
            if columns = mutation.cfmap[m.cfmap.keys.first]
              columns.concat(m.cfmap.values.first)
            else
              mutation.cfmap.merge!(m.cfmap)
            end
          else
            mutation_class[m.key] = m
          end
        else
          mutations[m.class] = {m.key => m}
        end
      end
    end
            
    @batch = compact_batch
  end
  
  def dispatch_mutations!
    @batch.each do |args| 
      case args
      when Array 
        _remove(*args)
      when BatchMutationSuper, BatchMutation 
        _insert(*args)
      end
    end
  end  
  
  def dump(object)
    # Special-case nil as the empty byte array
    return "" if object == nil
    @serializer.dump(object)
  end
  
  def load(object)
    return nil if object == ""  
    @serializer.load(object)
  end  
end
