require 'mingo'
require 'active_support/memoizable'
require 'indextank'
require 'will_paginate/finders/base'
require 'hashie/mash'
require 'net/http'
require 'active_support/cache'

class User < Mingo
  property :user_id
  property :username
  property :twitter
  property :twitter_id
  
  extend ActiveSupport::Memoizable
  
  class NotFound < RuntimeError; end
  
  def self.lookup(id)
    if id =~ /\D/
      first(username: id) or raise NotFound
    else
      self[id]
    end
  end
  
  def self.[](id)
    (first(user_id: id.to_i) || new(user_id: id.to_i)).tap do |user|
      unless user.username
        user.username = user.instagram_info.username
        user.save
      end
    end
  end
  
  def self.find_by_instagram_url(url)
    id = Instagram::Discovery.discover_user_id(url)
    self[id] if id
  end
  
  def instagram_info
    Instagram::user(self.user_id)
  end
  memoize :instagram_info
  
  def photos(max_id = nil)
    params = { count: 20 }
    params[:max_id] = max_id.to_s if max_id
    Instagram::user_recent_media(self.user_id, params)
  end
end

module Instagram
  module Discovery
    def self.discover_user_id(url)
      url = Addressable::URI.parse url unless url.respond_to? :host
      $1.to_i if get_url(url) =~ %r{profiles/profile_(\d+)_}
    end
  
    PermalinkRe = %r{http://instagr\.am/p/[/\w-]+}
    TwitterSearch = Addressable::URI.parse 'http://search.twitter.com/search.json'
    TwitterTimeline = Addressable::URI.parse 'http://api.twitter.com/1/statuses/user_timeline.json'
  
    def self.search_twitter(username)
      detect = Proc.new { |tweet| return [$&, tweet['id']] if tweet['text'] =~ PermalinkRe }
    
      url = TwitterSearch.dup
      url.query_values = { q: "from:#{username} instagr.am" }
      data = JSON.parse get_url(url)
      data['results'].each(&detect)
    
      url = TwitterTimeline.dup
      url.query_values = { screen_name: username, count: "200", trim_user: '1' }
      data = JSON.parse get_url(url)
      data.each(&detect)
    
      return nil
    end
  
    def self.get_url(url)
      Net::HTTP.get(url)
    end
  end
  
  module SuperchargedConnection
    private

    def connection(raw = false)
      faraday = super
      faraday.builder.build do |b|
        # JSON parser should be after Mashify but because of on_complete callbacks it has to be this way
        b.use Faraday::Response::ParseJson unless raw or format.to_s.downcase != 'json'
        b.use Faraday::Response::Mashify unless raw
        b.use Faraday::Request::OAuth2, client_id, access_token
        b.use CacheResponse
        b.use Instrumentation
        b.use Faraday::Response::RaiseHttp4xx
        b.use Faraday::Response::RaiseHttp5xx
        b.adapter(adapter)
      end
      faraday
    end

    class Instrumentation
      def initialize(app) @app = app end

      def call(env)
        ActiveSupport::Notifications.instrument('request.faraday', env) do
          @app.call(env)
        end
      end
    end

    class CacheResponse
      def self.cache
        @cache ||= ActiveSupport::Cache::FileStore.new \
          Sinatra::Application.settings.cache_dir,
          namespace: 'instagram',
          expires_in: Sinatra::Application.settings.production? ? 3.minutes : 1.hour
      end
      
      def initialize(app)
        @app = app
      end

      def call(env)
        if env[:method] == :get
          cache_key = normalize_url(env).request_uri

          if cached_response = self.class.cache.read(cache_key)
            merge_response(env, cached_response)
          else
            response = @app.call(env)
            self.class.cache.write(cache_key, response)
            response
          end
        else
          @app.call(env)
        end
      end

      def normalize_url(env)
        url = env[:url]
        unless url.path.include? '/self/'
          url = url.dup
          query = url.query_values
          query.delete 'access_token'
          url.query_values = query
        end
        url
      end

      def merge_response(env, cached)
        response = env[:response]
        response.status, response.headers, response.body = cached.status, cached.headers, cached.body
        env.update status: response.status, body: response.body, response_headers: response.headers
        response
      end
    end
  end
  
  module DumpableResponse
    def marshal_dump
      [@status, @headers, @body]
    end

    def marshal_load(data)
      self.status, self.headers, self.body = data
    end
  end

  ::Instagram::API.class_eval do
    include SuperchargedConnection
  end
  
  ::Faraday::Response.class_eval do
    include DumpableResponse
  end
end

# mimics Instagram::Media
class IndexedPhoto < Struct.new(:id, :caption, :thumbnail_url, :large_url, :username, :taken_at, :filter_name)
  Fields = 'text,thumbnail_url,username,timestamp,big,filter'

  class << self
    include WillPaginate::Finders::Base

    protected

    def wp_query(query_options, pager, args, &block)
      query = args.first
      filter = query_options.delete(:filter)
      query = "#{query} AND filter:#{filter}" if filter

      params = {:len => pager.per_page, :start => pager.offset, :fetch => Fields}.update(query_options)
      data = ActiveSupport::Notifications.instrument('search.indextank', {:query => query}.update(params)) do
        search_index.search(query, params)
      end
      pager.total_entries = data['matches']
      pager.replace data['results'].map { |item| new item }
    end

    def search_index
      Sinatra::Application.settings.search_index
    end
  end

  self.per_page = 32

  def initialize(hash)
    super hash['docid'], hash['text'], hash['thumbnail_url'], hash['big'],
          hash['username'], Time.at(hash['timestamp'].to_i), hash['filter']
  end

  User = Struct.new(:id, :full_name, :username)
  Caption = Struct.new(:text)

  def user
    @user ||= User.new(nil, nil, username)
  end
  
  def caption
    if text = super
      @caption ||= Caption.new(text)
    end
  end
  
  def images
    @images ||= Hashie::Mash.new \
      thumbnail: { url: thumbnail_url, width: 150, height: 150 },
      standard_resolution: { url: large_url, width: 612, height: 612 }
  end
end
