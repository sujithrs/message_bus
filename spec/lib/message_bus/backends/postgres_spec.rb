require_relative '../../../spec_helper'
require 'message_bus'

if MESSAGE_BUS_CONFIG[:backend] == :postgres || MESSAGE_BUS_CONFIG[:backend] == :memory
describe PUB_SUB_CLASS do

  def new_test_bus
    PUB_SUB_CLASS.new(MESSAGE_BUS_CONFIG.merge(:db => 10))
  end

  before do
    @bus = new_test_bus
    @bus.reset!
  end

  describe "readonly" do

    after do
      @bus.pub_redis.slaveof "no", "one"
    end

    it "should be able to store messages in memory for a period while in read only" do

      skip "This spec changes redis behavior that in turn means other specs run slow"

      @bus.pub_redis.slaveof "127.0.0.80", "666"
      @bus.max_in_memory_publish_backlog = 2

      3.times do
        result = @bus.publish "/foo", "bar"
        result.must_equal nil
      end

      @bus.pub_redis.slaveof "no", "one"
      sleep 0.01

      @bus.backlog("/foo", 0).map(&:data).must_equal ["bar","bar"]

    end
  end

  it "should be able to access the backlog" do
    @bus.publish "/foo", "bar"
    @bus.publish "/foo", "baz"

    @bus.backlog("/foo", 0).to_a.must_equal [
      MessageBus::Message.new(1,1,'/foo','bar'),
      MessageBus::Message.new(2,2,'/foo','baz')
    ]
  end

  it "should initialize with max_backlog_size" do
    PUB_SUB_CLASS.new({},2000).max_backlog_size.must_equal 2000
  end

  it "should truncate channels correctly" do
    @bus.max_backlog_size = 2
    4.times do |t|
      @bus.publish "/foo", "1#{t}"
    end

    @bus.backlog("/foo").to_a.must_equal [
      MessageBus::Message.new(3,3,'/foo','12'),
      MessageBus::Message.new(4,4,'/foo','13'),
    ]
  end

  it "should truncate global backlog correctly" do
    @bus.max_global_backlog_size = 2
    @bus.publish "/foo", "11"
    @bus.publish "/bar", "21"
    @bus.publish "/baz", "31"

    @bus.global_backlog.length.must_equal 2
  end

  it "should support clear_every setting" do
    @bus.clear_every = 5
    @bus.max_global_backlog_size = 2
    @bus.publish "/foo", "11"
    @bus.publish "/bar", "21"
    @bus.publish "/baz", "31"
    @bus.publish "/bar", "41"
    @bus.global_backlog.length.must_equal 4

    @bus.publish "/baz", "51"
    @bus.global_backlog.length.must_equal 2
  end

  it "should be able to grab a message by id" do
    id1 = @bus.publish "/foo", "bar"
    id2 = @bus.publish "/foo", "baz"
    @bus.get_message("/foo", id2).must_equal MessageBus::Message.new(2, 2, "/foo", "baz")
    @bus.get_message("/foo", id1).must_equal MessageBus::Message.new(1, 1, "/foo", "bar")
  end

  it "should be able to access the global backlog" do
    @bus.publish "/foo", "bar"
    @bus.publish "/hello", "world"
    @bus.publish "/foo", "baz"
    @bus.publish "/hello", "planet"

    @bus.global_backlog.to_a.must_equal [
      MessageBus::Message.new(1, 1, "/foo", "bar"),
      MessageBus::Message.new(2, 2, "/hello", "world"),
      MessageBus::Message.new(3, 3, "/foo", "baz"),
      MessageBus::Message.new(4, 4, "/hello", "planet")
    ]
  end

  it "should correctly omit dropped messages from the global backlog" do
    @bus.max_backlog_size = 1
    @bus.publish "/foo", "a1"
    @bus.publish "/foo", "b1"
    @bus.publish "/bar", "a1"
    @bus.publish "/bar", "b1"

    @bus.global_backlog.to_a.must_equal [
      MessageBus::Message.new(2, 2, "/foo", "b1"),
      MessageBus::Message.new(4, 4, "/bar", "b1")
    ]
  end

  it "should have the correct number of messages for multi threaded access" do
    threads = []
    4.times do
      threads << Thread.new do
        bus = @bus
        25.times {
          bus.publish "/foo", ".."
        }
      end
    end

    threads.each{|t| t.join}
    @bus.backlog("/foo").length == 100
  end

  it "should be able to subscribe globally with recovery" do
    @bus.publish("/foo", "11")
    @bus.publish("/bar", "12")
    got = []

    t = Thread.new do
      @bus.global_subscribe(0) do |msg|
        got << msg
      end
    end

    @bus.publish("/bar", "13")

    wait_for(100) do
      got.length == 3
    end

    t.kill

    got.length.must_equal 3
    got.map{|m| m.data}.must_equal ["11","12","13"]
  end

  it "should be able to encode and decode messages properly" do
    m = MessageBus::Message.new 1,2,'||','||'
    MessageBus::Message.decode(m.encode).must_equal m
  end

  it "should handle subscribe on single channel, with recovery" do
    @bus.publish("/foo", "11")
    @bus.publish("/bar", "12")
    got = []

    t = Thread.new do
      @bus.subscribe("/foo",0) do |msg|
        got << msg
      end
    end

    @bus.publish("/foo", "13")

    wait_for(100) do
      got.length == 2
    end

    t.kill

    got.map{|m| m.data}.must_equal ["11","13"]
  end

  it "should not get backlog if subscribe is called without params" do
    @bus.publish("/foo", "11")
    got = []

    t = Thread.new do
      @bus.subscribe("/foo") do |msg|
        got << msg
      end
    end

    # sleep 50ms to allow the bus to correctly subscribe,
    #   I thought about adding a subscribed callback, but outside of testing it matters less
    sleep 0.05

    @bus.publish("/foo", "12")

    wait_for(100) do
      got.length == 1
    end

    t.kill

    got.map{|m| m.data}.must_equal ["12"]
  end

  it "should allow us to get last id on a channel" do
    @bus.last_id("/foo").must_equal 0
    @bus.publish("/foo", "11")
    @bus.last_id("/foo").must_equal 1
  end

end
end
