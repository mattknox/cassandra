
require 'zlib'
require 'rubygems'
require 'thrift'

HERE = File.expand_path(File.dirname(__FILE__))

$LOAD_PATH << "#{HERE}/../vendor/gen-rb"
require "#{HERE}/../vendor/gen-rb/cassandra"

$LOAD_PATH << "#{HERE}"
require 'cassandra/array'
require 'cassandra/time'
require 'cassandra/comparable'
require 'cassandra/uuid'
require 'cassandra/long'
require 'cassandra/safe_client'
require 'cassandra/serialization'
require 'cassandra/ordered_hash'
require 'cassandra/constants'
require 'cassandra/helper'
require 'cassandra/cassandra'
