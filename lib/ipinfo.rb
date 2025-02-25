# frozen_string_literal: true

require 'cgi'
require 'ipaddr'
require 'ipinfo/adapter'
require 'ipinfo/cache/default_cache'
require 'ipinfo/errors'
require 'ipinfo/response'
require 'ipinfo/version'
require 'json'
require_relative 'ipinfo/ipAddressMatcher'

module IPinfo
    DEFAULT_CACHE_MAXSIZE = 4096
    DEFAULT_CACHE_TTL = 60 * 60 * 24
    DEFAULT_COUNTRY_FILE = File.join(File.dirname(__FILE__),
                                     'ipinfo/countries.json')
    DEFAULT_EU_COUNTRIES_FILE = File.join(File.dirname(__FILE__),
                                     'ipinfo/eu.json')
    DEFAULT_COUNTRIES_FLAG_FILE = File.join(File.dirname(__FILE__),
                                     'ipinfo/flags.json')
    DEFAULT_COUNTRIES_CURRENCIES_FILE = File.join(File.dirname(__FILE__),
                                     'ipinfo/currency.json')
    DEFAULT_CONTINENT_FILE = File.join(File.dirname(__FILE__),
                                     'ipinfo/continent.json')
    RATE_LIMIT_MESSAGE = 'To increase your limits, please review our ' \
                         'paid plans at https://ipinfo.io/pricing'
    # Base URL to get country flag image link.
    # "PK" -> "https://cdn.ipinfo.io/static/images/countries-flags/PK.svg"
    COUNTRY_FLAGS_URL = "https://cdn.ipinfo.io/static/images/countries-flags/"


    class << self
        def create(access_token = nil, settings = {})
            IPinfo.new(access_token, settings)
        end
    end
end

class IPinfo::IPinfo
    include IPinfo
    attr_accessor :access_token, :countries, :httpc

    def initialize(access_token = nil, settings = {})
        @access_token = access_token
        @httpc = prepare_http_client(settings.fetch('http_client', nil))

        maxsize = settings.fetch('maxsize', DEFAULT_CACHE_MAXSIZE)
        ttl = settings.fetch('ttl', DEFAULT_CACHE_TTL)
        @cache = settings.fetch('cache', DefaultCache.new(ttl, maxsize))
        @countries = prepare_json(settings.fetch('countries',
                                                      DEFAULT_COUNTRY_FILE))
        @eu_countries = prepare_json(settings.fetch('eu_countries',
                                                      DEFAULT_EU_COUNTRIES_FILE))
        @countries_flags = prepare_json(settings.fetch('countries_flags',
                                                      DEFAULT_COUNTRIES_FLAG_FILE))
        @countries_currencies = prepare_json(settings.fetch('countries_currencies',
                                                      DEFAULT_COUNTRIES_CURRENCIES_FILE))
        @continents = prepare_json(settings.fetch('continents',
                                                      DEFAULT_CONTINENT_FILE))
    end

    def details(ip_address = nil)
        details = request_details(ip_address)
        if details.key? :country
            details[:country_name] =
                @countries.fetch(details.fetch(:country), nil)
            details[:is_eu] =
                @eu_countries.include?(details.fetch(:country))
            details[:country_flag] =
                @countries_flags.fetch(details.fetch(:country), nil)
            details[:country_currency] =
                @countries_currencies.fetch(details.fetch(:country), nil)
            details[:continent] = 
                @continents.fetch(details.fetch(:country), nil)
            details[:country_flag_url] = COUNTRY_FLAGS_URL + details.fetch(:country) + ".svg"
        end

        if details.key? :ip
            details[:ip_address] =
                IPAddr.new(details.fetch(:ip))
        end

        if details.key? :loc
            loc = details.fetch(:loc).split(',')
            details[:latitude] = loc[0]
            details[:longitude] = loc[1]
        end

        Response.new(details)
    end

    def get_map_url(ips)
        if !ips.kind_of?(Array)
            return JSON.generate({:error => 'Invalid input. Array required!'})
        end
        if ips.length > 500000
            return JSON.generate({:error => 'No more than 500,000 ips allowed!'})
        end

        json_ips = JSON.generate({:ips => ips})
        res = @httpc.post('/tools/map', json_ips)

        obj = JSON.parse(res.body)
        obj['reportUrl']
    end

    def batch_requests(url_array, api_token)
        result = Hash.new
        lookup_ips = []

        url_array.each { |url|
            ip = @cache.get(cache_key(url))

            unless ip.nil?
                result.store(url, ip)
            else
                lookup_ips << url
            end
        }

        if lookup_ips.empty?
            return result
        end

        begin
            lookup_ips.each_slice(1000){ |ips|
                json_arr = JSON.generate(lookup_ips)
                res = @httpc.post("/batch?token=#{api_token}", json_arr, 5)

                raise StandardError, "Request Quota Exceeded" if res.status == 429

                data = JSON.parse(res.body)
                data.each { |key, val|
                    @cache.set(cache_key(key), val)
                }

                result.merge!(data)
            }

        rescue StandardError => e
            return e.message
        end

        result
    end

    protected

    def request_details(ip_address = nil)
        if isBogon(ip_address)
            details[:ip] = ip_address
            details[:bogon] = true
            details[:ip_address] = IPAddr.new(ip_address)

            return details
        end

        res = @cache.get(cache_key(ip_address))
        return res unless res.nil?

        response = @httpc.get(escape_path(ip_address))

        if response.status.eql?(429)
            raise RateLimitError,
                  RATE_LIMIT_MESSAGE
        end

        details = JSON.parse(response.body, symbolize_names: true)
        @cache.set(cache_key(ip_address), details)
        details
    end

    def prepare_http_client(httpc = nil)
        @httpc = if httpc
                     Adapter.new(access_token, httpc)
                 else
                     Adapter.new(access_token)
                 end
    end

    def prepare_json(filename)
        file = File.read(filename)
        JSON.parse(file)
    end

    private

    def isBogon(ip)
        if ip.nil?
            return false
        end

        matcher_object = IpAddressMatcher.new(ip)
        matcher_object.matches
    end

    def escape_path(ip)
        ip ? "/#{CGI.escape(ip)}" : '/'
    end

    def cache_key(ip)
        "1:#{ip}"
    end
end
