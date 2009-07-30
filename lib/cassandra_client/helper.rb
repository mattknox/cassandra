class CassandraClient

  # A bunch of crap, mostly related to introspecting on column types
  module Helper
  
    private
    
    def is_super(column_family)
      @is_super[column_family] ||= column_family_property(column_family, 'Type') == "Super"
    end
    
    def column_name_class(column_family)
      @column_name_class[column_family] ||= column_name_class_for_key(column_family, "CompareWith")
    end
    
    def sub_column_name_class(column_family)
      @sub_column_name_class[column_family] ||= column_name_class_for_key(column_family, "CompareSubcolumnsWith")
    end
    
    def column_name_class_for_key(column_family, comparator_key)
      property = column_family_property(column_family, comparator_key)
      property =~ /.*\.(.*?)Type/
      self.class.const_get($1) # Long, UUID
    rescue NameError      
      String # UTF8, Ascii, Bytes, anything else
    rescue TypeError
      nil # Called sub_column_name_class on a standard column family
    end

    def column_family_property(column_family, key)
      @schema[column_family][key]
    rescue NoMethodError
      raise AccessError, "Invalid column family \"#{column_family}\""    
    end
    
    def assert_column_name_classes(column_family, columns, sub_columns = nil)      
      {Array(columns) => column_name_class(column_family), 
        Array(sub_columns) => sub_column_name_class(column_family)}.each do |columns, klass|
        columns.each do |column|         
          raise Comparable::TypeError, "Expected #{column.inspect} to be a #{klass}" if !column.is_a?(klass)
        end 
      end
    end
    
    def columns_to_hash(column_family, columns)
      columns_to_hash_for_classes(columns, column_name_class(column_family), sub_column_name_class(column_family))
    end
    
    def sub_columns_to_hash(column_family, columns)
      columns_to_hash_for_classes(columns, sub_column_name_class(column_family))
    end
    
    def columns_to_hash_for_classes(columns, column_name_class, sub_column_name_class = nil)
      hash = OrderedHash.new
      Array(columns).each do |c|
        hash[column_name_class.new(c.name)] = if c.is_a?(SuperColumn)
          # Pop the class stack, and recurse
          columns_to_hash_for_classes(c.columns, sub_column_name_class)
        else
          load(c.value)
        end
      end
      hash    
    end
    
    def hash_to_columns(column_family, hash, timestamp)
      assert_column_name_classes(column_family, hash.keys)
      hash_to_columns_without_assertion(column_family, hash, timestamp)
    end
    
    def hash_to_columns_without_assertion(column_family, hash, timestamp)
      hash.map do |column, value|
        Column.new(:name => column.to_s, :value => dump(value), :timestamp => timestamp)
      end    
    end    
    
    def hash_to_super_columns(column_family, hash, timestamp)
      assert_column_name_classes(column_family, hash.keys)      
      hash.map do |column, sub_hash|
        assert_column_name_classes(column_family, nil, sub_hash.keys)
        SuperColumn.new(:name => column.to_s, :columns => hash_to_columns_without_assertion(column_family, sub_hash, timestamp))
      end
    end    
  end
end
