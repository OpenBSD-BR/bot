# -*- coding: utf-8 -*-
require "uri"
require "mongo"
require "cinch"
require "cinch/plugins/identify"
require "cinch/plugins/urlscraper"
require "cinch/plugins/urbandict"
require "cinch/plugins/wikipedia"
require 'rubygems'
require 'simple-rss'
require 'open-uri'
require 'htmlentities'

# Revisar

require_relative "plugins/cleverbot"

include Mongo

def get_db
  #if ENV["MONGOHQ_URL"].nil?
  if ENV["MONGODB_URI"].nil?
    MongoClient.new("localhost", 27017).db("bluebot")
  else
    mongo_uri = ENV["MONGODB_URI"]
    db_name = mongo_uri[%r{/([^/\?]+)(\?|$)}, 1]
    MongoClient.from_uri(mongo_uri).db(db_name)
  end
end

db = get_db

rss = SimpleRSS.parse open('http://undeadly.org/cgi?action=rss')

bot = Cinch::Bot.new do
  configure do |c|
    c.server   =  ENV["BLUEBOT_SERVER"]  || "irc.freenode.org"
    c.channels = [ENV["BLUEBOT_CHANNEL"] || "#cinch-bots"]
    c.nick     =  ENV["BLUEBOT_NICK"]    || "bluebot"
    c.realname =  ENV["BLUEBOT_NICK"]    || "bluebot"
    c.user     =  ENV["BLUEBOT_NICK"]    || "bluebot"

    c.plugins.plugins = [Cinch::Plugins::Identify,
                         Cinch::Plugins::UrlScraper,
                         Cinch::Plugins::UrbanDict,
                         Cinch::Plugins::Wikipedia,
                         Cinch::Plugins::CleverBot]

    c.plugins.options[Cinch::Plugins::Identify] = {
      username: ENV["BLUEBOT_NICK"]     || "",
      password: ENV["BLUEBOT_PASSWORD"] || "",
      type:     :nickserv,
    }

    # Required by the Wikipedia and Urban Dictionary plugins
    c.shared[:cooldown] = {
      config: {
        c.channels.first => {
          global: 1,
          user:   1
        }
      }
    }
  end

  on :message, "!hello" do |m|
    m.reply "Hello, #{m.user.nick}!"
  end

  on :message, "!help" do |m|
    m.reply "See https://github.com/Bluebot/Bluebot#supported-commands for a list of supported actions."
    m.reply ""
    m.reply "!lmgtfy"
    m.reply "!google"
    m.reply "!journal"
    m.reply "!karma"
    m.reply "!quote"
  end

  # Let Me Google That For You

  on :message, /\A!lmgtfy (.+)/ do |m, what|
    m.reply "http://lmgtfy.com/?q=#{URI::encode(what)}"
  end  

  on :message, /\A!google (.+)/ do |m, what|
		m.reply "http://www.google.com/search?q=#{URI::encode(what)}"
  end  

  on :message, "!journal" do |m|
    m.reply rss.items.first.title
    rssLink = HTMLEntities.new.decode rss.items.first.link
    m.reply rssLink
  end

  # Karma

  on :message, /\A(\S+)\+\+/ do |m, what|
    add_karma(db, what, 1)
  end

  on :message, /\A(\S+)--/ do |m, what|
    add_karma(db, what, -1)
  end

  on :message, /\A!karma\Z/ do |m, num|
    m.reply get_karma(db, m.user.nick)
  end

  on :message, /\A!karma (\S+)/ do |m, what|
    m.reply get_karma(db, what)
  end  

  on :message, "!openbsd" do |m|
    m.reply "http://www.openbsd.org | http://www.openbsd-br.org"
  end

  # Quotes
  
  on :message, /\A!addquote (.+)/ do |m, quote|
    db["quotes"].insert({"quote" => quote})
    num = db["quotes"].count()
    m.reply "Added quote \##{num}: \"#{quote}\"."
  end

  on :message, /\A!quote\Z/ do |m, num|
    m.reply get_quote(db, 1 + rand(db["quotes"].count()))
  end

  on :message, /\A!quote (\d+)/ do |m, num|
    m.reply get_quote(db, num)
  end

  on :message, "!lastquote" do |m|
    m.reply get_quote(db, db["quotes"].count())
  end

  on :message, /\A!searchquote (.+)/ do |m, keywords|
    indexes = []
    quotes  = db["quotes"].find().to_a
    quotes.each_index do |idx|
      indexes << (idx + 1) unless quotes[idx]["quote"].downcase.index(keywords.downcase).nil?
    end
    if indexes.empty?
      m.reply "No quotes found."
    else
      m.reply "Quotes matching \"#{keywords}\": #{indexes}."
    end
  end

  # Seen

  on :join do |m|
    m.channel.users.keys.each do |user|
      saw(db, user.nick)
    end
  end

  on :message do |m|
    saw(db, m.user.nick)
  end

  on :leaving do |m|
    saw(db, m.user.nick)
  end

  on :message, /\A!seen (\S+)/ do |m, who|
    online_users = m.channel.users.keys.map do |user|
      user.nick.downcase
    end

    if online_users.include?(who.downcase)
      m.reply "#{who} is online right now, you dummy."
    else
      m.reply last_seen(db, who)
    end
  end
end

# Quotes

def get_quote(db, num)
  begin
    total = db["quotes"].count()
    quote = db["quotes"].find().to_a[num.to_i - 1]["quote"]
    "Quote (#{num}/#{total}): \"#{quote}\"."
  rescue
    "Quote not found."
  end
end

# Karma

def get_karma(db, what)
  item  = db["karma"].find({"item" => what.downcase}).next
  karma = item.nil? ? 0 : item["karma"]
  "Karma for #{what}: #{karma}."  
end

def add_karma(db, what, how_much)
  item  = db["karma"].find({"item" => what.downcase}).next
  if item.nil?
    db["karma"].insert({"item" => what.downcase, "karma" => how_much})
  else
    karma = item["karma"].to_i + how_much
    db["karma"].update({"item" => what.downcase}, {"$set" => {"karma" => karma}})
  end    
end

# Seen

def saw(db, who)
  item  = db["seen"].find({"item" => who.downcase}).next
  if item.nil?
    db["seen"].insert({"item" => who.downcase, "when" => Time.now.to_i})
  else
    db["seen"].update({"item" => who.downcase}, {"$set" => {"when" => Time.now.to_i}})
  end    
end

def last_seen(db, who)
  item  = db["seen"].find({"item" => who.downcase}).next
  if item.nil?
    "I've never seen #{who} here."
  else
    t = Time.at(item["when"].to_i).to_s
    "#{who} was last seen on #{t}."
  end
end

bot.start
