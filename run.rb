require 'rubygems'
require 'active_record'
require 'yaml'
require 'logger'
require 'open-uri'
require 'faraday'
require 'json'

#>======================Init=========================
ENV['RACK_ENV'] ||= "development"
dbconfig = YAML::load(File.open('database.yml'))
ActiveRecord::Base.establish_connection(dbconfig["panda_production"])
ActiveRecord::Base.logger = Logger.new(File.open('database.log', 'a'))
$err = Logger.new(File.open('err.log', 'a'))
$bad = Logger.new(File.open('bad.log', 'a'))
#<======================Init=======================

#>======================Models=======================
class IpInfo < ActiveRecord::Base
  has_one :ip_address, foreign_key: :ip, primary_key: :ip
  after_save :remove_ip_address
  def remove_ip_address
    self.ip_address.destroy
  end
end

class IpAddress < ActiveRecord::Base
  belongs_to :ip_info
end

#<===================================================

module DateManager
  class CaptureIpAddresses
    IP_D = 255
    class << self
      def descartes set_x, set_y
    		result = []
    		set_x.each do |x|
    			set_y.each do |y|
    				result << [x,y]
    			end
    		end
    		result
    	end

      def gen_ip_address
        column_sets = []
        column_sets << [ARGV.first.to_i]
        ip_part = (0..255).to_a
        2.times{ column_sets << ip_part }
    		result = column_sets.shift
    		while not column_sets.empty?
    			set_x = column_sets.shift
    			result = descartes(result, set_x);
    		end
        puts "Ip item Length: #{result.size}"
    		result.map(&:flatten!)
        puts "Adding d port into ip item..."
        result.collect! do |x|
          x << IP_D
          x.join('.')
        end
        puts "Almost done return result."
        result
      end

      def capture_responses ip_addresses
        puts "Starts to capture the responses..."
        puts "Plan to capture #{ip_addresses.size} times"
        connection = Faraday.new(:url => 'http://ip.taobao.com') do |faraday|
          faraday.request  :url_encoded             # form-encode POST params
          # faraday.response :logger                  # log requests to STDOUT
          faraday.adapter  Faraday.default_adapter  # make requests with Net::HTTP
        end
        responses = {}
        succ = 0
        failed = 0
        ip_addresses.each do |ip_address|
          begin
            response = connection.get "/service/getIpInfo.php?ip=#{ip_address}"
            if response.success?
              responses[ip_address] = response.body
              succ += 1
            else
              failed += 1
            end
          rescue Exception => e
            $err.info ip_address
            $err.info e
            failed += 1
            next
          end
        end
        puts "Capture Succ: #{succ}, Failed: #{failed}"
        responses
      end

      def parse_response http_responses
        puts "Start to parse html document and pick out the usefull info..."
        http_doc = ""
        succ = 0
        failed =0
        ActiveRecord::Base.transaction do
          http_responses.each do |k,v|
            begin
              res = JSON.parse v
              raise "Failed!" if res["code"].eql?(1)
              data = res["data"]
              IpInfo.create(res["data"])
              succ += 1
            rescue Exception => e
              $bad.info k
              $err.info k
              $err.info e
              failed += 1
              next
            end
          end
        end
        puts "Parsed Total: #{http_responses.size}, Succ: #{succ}, Failed: #{failed}."
      end

      def init_ip_address
        puts "Init Ip Address..."
        ip_addresses = gen_ip_address
        ActiveRecord::Base.transaction do
          ip_addresses.each do |ip_address|
              IpAddress.create(ip: ip_address)
          end
        end
      end

      def pick_ip_addresses num
        records = IpAddress.where("ip like '#{ARGV.first.to_i}.%'").limit(num)
        records.map(&:ip)
      end

      def ip_addresses_count
        IpAddress.where("ip like '#{ARGV.first.to_i}.%'").count
      end

      def run
        raise "wrong argv size." if ARGV.size < 1
        init_ip_address unless ARGV.size.eql? 2
        while(ip_addresses_count > 0)
          ip_addresses = pick_ip_addresses 1000
          http_responses = capture_responses ip_addresses
          parse_response http_responses
          puts "Left: #{ip_addresses_count}"
        end
      end
    end
  end
end

DateManager::CaptureIpAddresses.run
