
# ENV['RACK_ENV'] = 'development'

require 'sinatra/base'
require 'mysql2'
require 'mysql2-cs-bind'
require "sinatra/reloader"
require "erubis"
require "tilt/erubis"
require 'redis'
require 'redis-namespace'
require 'oj'
require 'open3'
require 'rack-lineprof'

Oj.default_options = {
  symbol_keys: true
}




module Isucon5
  class AuthenticationError < StandardError; end
  class PermissionDenied < StandardError; end
  class ContentNotFound < StandardError; end
  module TimeWithoutZone
    def to_s
      strftime("%F %H:%M:%S")
    end
  end
  ::Time.prepend TimeWithoutZone
end

class Isucon5::WebApp < Sinatra::Base

  # use Rack::Lineprof, profile: 'app.rb'

  def initialize(*args)
    @redis = Redis.new(path: '/var/run/redis/redis.sock')
    @us = Redis::Namespace.new(:users, redis: @redis)
    @rs = Redis::Namespace.new(:relations, redis: @redis)
    @fs = Redis::Namespace.new(:footprints, redis: @redis)
    super(*args)
  end

  configure :development do
    register Sinatra::Reloader
  end
  use Rack::Session::Cookie
  set :erb, escape_html: true
  set :public_folder, File.expand_path('../../static', __FILE__)
  #set :sessions, true
  set :session_secret, ENV['ISUCON5_SESSION_SECRET'] || 'beermoris'
  set :protection, true

  helpers do
    def config
      @config ||= {
        db: {
          host: ENV['ISUCON5_DB_HOST'] || 'localhost',
          port: ENV['ISUCON5_DB_PORT'] && ENV['ISUCON5_DB_PORT'].to_i,
          username: ENV['ISUCON5_DB_USER'] || 'root',
          password: ENV['ISUCON5_DB_PASSWORD'],
          database: ENV['ISUCON5_DB_NAME'] || 'isucon5q',
        },
      }
    end

    def db
      return Thread.current[:isucon5_db] if Thread.current[:isucon5_db]
      client = Mysql2::Client.new(
        host: config[:db][:host],
        port: config[:db][:port],
        username: config[:db][:username],
        password: config[:db][:password],
        database: config[:db][:database],
        reconnect: true,
      )
      client.query_options.merge!(symbolize_keys: true)
      Thread.current[:isucon5_db] = client
      client
    end

    def authenticate(email, password)
      query = <<SQL
SELECT u.id AS id, u.account_name AS account_name, u.nick_name AS nick_name, u.email AS email
FROM users u
JOIN salts s ON u.id = s.user_id
WHERE u.email = ? AND u.passhash = SHA2(CONCAT(?, s.salt), 512)
SQL
      result = db.xquery(query, email, password).first
      unless result
        raise Isucon5::AuthenticationError
      end
      session[:user_id] = result[:id]
      result
    end

    def current_user
      return @user if @user
      unless session[:user_id]
        return nil
      end
      # @user = db.xquery('SELECT id, account_name, nick_name, email FROM users WHERE id=?', session[:user_id]).first
      # p session[:user_id]
      # p session[:user_id]
      # @user = Hash[@us.hgetall(session[:user_id].to_i).map{ |k,v| [k.to_sym, v] }]
      @user = Oj.load(@us.get(session[:user_id]))
      unless @user
        session[:user_id] = nil
        session.clear
        raise Isucon5::AuthenticationError
      end
      @user
    end

    def authenticated!
      unless current_user
        redirect '/login'
      end
    end

    def get_user(user_id)
      user = Oj.load(@us.get(user_id)) || db.xquery('SELECT id, account_name, nick_name, email, passhash FROM users WHERE id = ?', user_id).first
      raise Isucon5::ContentNotFound unless user
      user
    end

    def user_from_account(account_name)
      user = db.xquery('SELECT id, account_name, nick_name, email, passhash FROM users WHERE account_name = ?', account_name).first
      raise Isucon5::ContentNotFound unless user
      user
    end

    def is_friend?(another_id)
      user_id = session[:user_id]
      @rs.hexists(user_id, another_id)
      # query = 'SELECT COUNT(1) AS cnt FROM relations WHERE (one = ? AND another = ?) OR (one = ? AND another = ?)'
      # cnt = db.xquery(query, user_id, another_id, another_id, user_id).first[:cnt]
      # cnt.to_i > 0 ? true : false
    end

    def is_friend_account?(account_name)
      is_friend?(user_from_account(account_name)[:id])
    end

    def permitted?(another_id)
      another_id == current_user[:id] || is_friend?(another_id)
    end

    def mark_footprint(user_id)
      if user_id != current_user[:id]
        #query = 'REPLACE INTO footprints (user_id,owner_id,date) VALUES (?,?,now())'
        #db.xquery(query, user_id, current_user[:id])

        now = Time.now
        @fs.zadd(user_id, now.to_i, "#{current_user[:id]}##{now.strftime('%F')}")

        Thread.new do
          footprints_page(user_id)
        end
      end
    end

    def footprints(user_id, count)
=begin
      query = <<SQL
SELECT user_id, owner_id, DATE(created_at) AS date, MAX(created_at) as updated
FROM footprints
WHERE user_id = ?
GROUP BY user_id, owner_id, DATE(created_at)
ORDER BY updated DESC
LIMIT #{count}
SQL

      db.xquery(query, user_id)
=end
      @fs.zrevrange(user_id, 0, count-1, with_scores: true).map{|id_and_date, time| [id_and_date.split('#')[0], Time.at(time).strftime('%F %T')]}
    end

    PREFS = %w(
      未入力
      北海道 青森県 岩手県 宮城県 秋田県 山形県 福島県 茨城県 栃木県 群馬県 埼玉県 千葉県 東京都 神奈川県 新潟県 富山県
      石川県 福井県 山梨県 長野県 岐阜県 静岡県 愛知県 三重県 滋賀県 京都府 大阪府 兵庫県 奈良県 和歌山県 鳥取県 島根県
      岡山県 広島県 山口県 徳島県 香川県 愛媛県 高知県 福岡県 佐賀県 長崎県 熊本県 大分県 宮崎県 鹿児島県 沖縄県
    )
    def prefectures
      PREFS
    end
  end

  error Isucon5::AuthenticationError do
    session[:user_id] = nil
    halt 401, erubis(:login, layout: false, locals: { message: 'ログインに失敗しました' })
  end

  error Isucon5::PermissionDenied do
    halt 403, erubis(:error, locals: { message: '友人のみしかアクセスできません' })
  end

  error Isucon5::ContentNotFound do
    halt 404, erubis(:error, locals: { message: '要求されたコンテンツは存在しません' })
  end

  get '/login' do
    session.clear
    erb :login, layout: false, locals: { message: '高負荷に耐えられるSNSコミュニティサイトへようこそ!' }
  end

  post '/login' do
    authenticate params['email'], params['password']
    redirect '/'
  end

  get '/logout' do
    session[:user_id] = nil
    session.clear
    redirect '/login'
  end

  get '/' do
    authenticated!

    profile = db.xquery('SELECT first_name, last_name, sex, birthday, pref FROM profiles WHERE user_id = ?', current_user[:id]).first
    entries_query = 'SELECT id, title, private FROM entries WHERE user_id = ? ORDER BY created_at LIMIT 5'
    entries = db.xquery(entries_query, current_user[:id])
      .map{ |entry| entry[:is_private] = (entry[:private] == 1); entry }

    comments_for_me_query = <<SQL
SELECT c.id AS id, c.entry_id AS entry_id, c.user_id AS user_id, LEFT(c.comment, 31) AS comment, c.created_at AS created_at
FROM comments c
JOIN entries e ON c.entry_id = e.id
WHERE e.user_id = ?
ORDER BY c.id DESC
LIMIT 10
SQL
    comments_for_me = db.xquery(comments_for_me_query, current_user[:id])

    friends_ids = @rs.hgetall(current_user[:id]).keys
    friends_ids_str = friends_ids.join(',')
    friends_count = friends_ids.size
    entries_of_friends_query = <<SQL
SELECT id, user_id, title, created_at
FROM entries
WHERE user_id IN (#{friends_ids_str})
ORDER BY id DESC
LIMIT 10
SQL
    entries_of_friends = db.xquery(entries_of_friends_query)

    comments_of_friends_query = <<SQL
SELECT c.user_id AS user_id, e.user_id AS owner_id, c.created_at AS created_at, e.id AS entry_id, LEFT(c.comment, 31) AS comment
FROM comments c
JOIN entries e ON c.entry_id = e.id
WHERE c.user_id IN (#{friends_ids_str})
AND (
  e.private = 0
  OR
  e.private = 1 AND (e.user_id = ? OR e.user_id IN (#{friends_ids_str}))
)
ORDER BY c.id DESC LIMIT 10
SQL
    comments_of_friends = db.xquery(comments_of_friends_query, current_user[:id])

    # friends_query = 'SELECT * FROM relations WHERE one = ? OR another = ? ORDER BY created_at DESC'
    # friends_map = {}
    # db.xquery(friends_query, current_user[:id], current_user[:id]).each do |rel|
    #   key = (rel[:one] == current_user[:id] ? :another : :one)
    #   friends_map[rel[key]] ||= rel[:created_at]
    # end
    # friends = friends_map.map{|user_id, created_at| [user_id, created_at]}

=begin
    query = <<SQL
SELECT user_id, owner_id, date, created_at AS updated
FROM footprints
WHERE user_id = ?
ORDER BY updated DESC
LIMIT 10
SQL
    footprints = db.xquery(query, current_user[:id])
=end

    locals = {
      profile: profile || {},
      entries: entries,
      comments_for_me: comments_for_me,
      entries_of_friends: entries_of_friends,
      comments_of_friends: comments_of_friends,
      friends_count: friends_count,
      footprints: footprints(current_user[:id], 10)
    }
    erb :index, locals: locals
  end

  get '/profile/:account_name' do
    authenticated!
    owner = user_from_account(params['account_name'])
    prof = db.xquery('SELECT first_name, last_name, sex, birthday, pref FROM profiles WHERE user_id = ?', owner[:id]).first
    prof = {} unless prof
    query = if permitted?(owner[:id])
              'SELECT id, private, LEFT(body,121) as body, created_at, title FROM entries WHERE user_id = ? ORDER BY created_at LIMIT 5'
            else
              'SELECT id, private, LEFT(body,121) as body, created_at, title FROM entries WHERE user_id = ? AND private=0 ORDER BY created_at LIMIT 5'
            end
    entries = db.xquery(query, owner[:id])
      .map{ |entry| entry[:is_private] = (entry[:private] == 1); entry[:title], entry[:content] = entry[:body].split(/\n/, 2); entry }
    mark_footprint(owner[:id])
    erb :profile, locals: { owner: owner, profile: prof, entries: entries, private: permitted?(owner[:id]) }
  end

  post '/profile/:account_name' do
    authenticated!
    if params['account_name'] != current_user[:account_name]
      raise Isucon5::PermissionDenied
    end
    args = [params['first_name'], params['last_name'], params['sex'], params['birthday'], params['pref']]

    prof = db.xquery('SELECT * FROM profiles WHERE user_id = ?', current_user[:id]).first
    if prof
      query = <<SQL
UPDATE profiles
SET first_name=?, last_name=?, sex=?, birthday=?, pref=?, updated_at=CURRENT_TIMESTAMP()
WHERE user_id = ?
SQL
      args << current_user[:id]
    else
      query = <<SQL
INSERT INTO profiles (user_id,first_name,last_name,sex,birthday,pref) VALUES (?,?,?,?,?,?)
SQL
      args.unshift(current_user[:id])
    end
    db.xquery(query, *args)
    redirect "/profile/#{params['account_name']}"
  end

  get '/diary/entries/:account_name' do
    authenticated!
    owner = user_from_account(params['account_name'])
    query = if permitted?(owner[:id])
              'SELECT id, private, body, created_at, title FROM entries WHERE user_id = ? ORDER BY created_at DESC LIMIT 20'
            else
              'SELECT id, private, body, created_at, title FROM entries WHERE user_id = ? AND private=0 ORDER BY created_at DESC LIMIT 20'
            end
    entries = db.xquery(query, owner[:id])
      .map{ |entry| entry[:is_private] = (entry[:private] == 1); entry[:title], entry[:content] = entry[:body].split(/\n/, 2); entry }
    mark_footprint(owner[:id])
    erb :entries, locals: { owner: owner, entries: entries, myself: (current_user[:id] == owner[:id]) }
  end

  get '/diary/entry/:entry_id' do
    authenticated!
    entry = db.xquery('SELECT id, user_id, private, body, created_at, title FROM entries WHERE id = ?', params['entry_id']).first
    raise Isucon5::ContentNotFound unless entry
    entry[:title], entry[:content] = entry[:body].split(/\n/, 2)
    entry[:is_private] = (entry[:private] == 1)
    owner = get_user(entry[:user_id])
    if entry[:is_private] && !permitted?(owner[:id])
      # raise Isucon5::PermissionDenied
      return status 403
    end
    comments = db.xquery('SELECT user_id, comment, created_at FROM comments WHERE entry_id = ?', entry[:id])
    mark_footprint(owner[:id])
    erb :entry, locals: { owner: owner, entry: entry, comments: comments }
  end

  post '/diary/entry' do
    authenticated!
    query = 'INSERT INTO entries (user_id, private, body, title) VALUES (?,?,?,?)'
    title = params['title'] || "タイトルなし"
    body = title + "\n" + params['content']
    db.xquery(query, current_user[:id], (params['private'] ? '1' : '0'), body, title)
    redirect "/diary/entries/#{current_user[:account_name]}"
  end

  post '/diary/comment/:entry_id' do
    authenticated!
    entry = db.xquery('SELECT * FROM entries WHERE id = ?', params['entry_id']).first
    unless entry
      raise Isucon5::ContentNotFound
    end
    entry[:is_private] = (entry[:private] == 1)
    if entry[:is_private] && !permitted?(entry[:user_id])
      raise Isucon5::PermissionDenied
    end
    query = 'INSERT INTO comments (entry_id, user_id, comment) VALUES (?,?,?)'
    db.xquery(query, entry[:id], current_user[:id], params['comment'])
    redirect "/diary/entry/#{entry[:id]}"
  end

  get '/footprints' do
    authenticated!

=begin
    query = <<SQL
SELECT user_id, owner_id, DATE(created_at) AS date, MAX(created_at) as updated
FROM footprints
WHERE user_id = ?
GROUP BY user_id, owner_id, DATE(created_at)
ORDER BY updated DESC
LIMIT 50
SQL
    footprints = db.xquery(query, current_user[:id])
=end
    # erb :footprints, locals: { footprints: footprints(current_user[:id], 50) }
    @fs.get("#{current_user[:id]}_p") #|| footprints_page(current_user[:id])
  end

  def footprints_page(user_id)
    rendered = erb :footprints, locals: { footprints: footprints(user_id, 50) }
    @fs.set("#{user_id}_p", rendered)
  end

  get '/friends' do
    authenticated!
    # query = 'SELECT * FROM relations WHERE one = ? OR another = ? ORDER BY created_at DESC'
    # friends = {}
    # db.xquery(query, current_user[:id], current_user[:id]).each do |rel|
    #   key = (rel[:one] == current_user[:id] ? :another : :one)
    #   friends[rel[key]] ||= rel[:created_at]
    # end
    # list = friends.map{|user_id, created_at| [user_id, created_at]}
    # list = @rs.hgetall(current_user[:id])#.sort_by{|k, v| v}.reverse
    #erb :friends, locals: { friends: list }
    @rs.get("#{current_user[:id]}_p") # || friends_page(current_user[:id])
  end

  def friends_page(user_id)
    friends = @rs.hgetall(user_id).map{|k, v| [get_user(k), v]}
    rendered = erb :friends, locals: { friends: friends }
    @rs.set("#{user_id}_p", rendered)
  end

  post '/friends/:account_name' do
    authenticated!
    unless is_friend_account?(params['account_name'])
      user = user_from_account(params['account_name'])
      unless user
        raise Isucon5::ContentNotFound
      end
      # db.xquery('INSERT INTO relations (one, another) VALUES (?,?), (?,?)', current_user[:id], user[:id], user[:id], current_user[:id])
      # ts = db.xquery('SELECT created_at FROM relations WHERE one = ? AND another = ?;', current_user[:id], user[:id]).first[:created_at]
      ts = Time.now.strftime('%F %T')
      @rs.hset(current_user[:id], user[:id], ts)
      @rs.hset(user[:id], current_user[:id], ts)

#      @rs.del("#{current_user[:id]}_p")
#      @rs.del("#{user[:id]}_p")
      Thread.new do
        footprints_page(current_user[:id])
        footprints_page(user[:id])
      end
      redirect '/friends'
    end
  end

  get '/initialize' do
    db.query("DELETE FROM relations WHERE id > 500000")
    db.query("DELETE FROM footprints WHERE id > 500000")
    db.query("DELETE FROM entries WHERE id > 500000")
    db.query("DELETE FROM comments WHERE id > 1500000")

    Open3.capture3("/bin/bash -c '/usr/bin/sudo systemctl stop redis.service'")
    Open3.capture3("/bin/bash -c '/usr/bin/sudo cp /var/lib/redis/backup.rdb /var/lib/redis/dump.rdb'")
    Open3.capture3("/bin/bash -c '/usr/bin/sudo systemctl start redis.service'")

    sleep 2

    ''
  end

  get '/initialize_and_backup' do
    db.query("DELETE FROM relations WHERE id > 500000")
    db.query("DELETE FROM footprints WHERE id > 500000")
    db.query("DELETE FROM entries WHERE id > 500000")
    db.query("DELETE FROM comments WHERE id > 1500000")
    # cache in memory
    query = <<SQL
SELECT *
FROM users u
JOIN salts s ON u.id = s.user_id
;
SQL
    @redis.flushdb
    p "redis flushed"
    db.xquery(query).each { |r|
      r.delete(:user_id)
      @us.set(r[:id], Oj.dump(r))
      # @us.hmset(r[:id], *r.to_a)
    }
    p "user set ok"
    query = <<SQL
SELECT *
FROM relations
;
SQL
    require 'set'
    hs = {}
    db.xquery(query).each do |r|
      hs[r[:one]] ||= []
      hs[r[:one]] << r[:another]
      hs[r[:one]] << r[:created_at]
      hs[r[:another]] ||= []
      hs[r[:another]] << r[:one]
      hs[r[:another]] << r[:created_at]
    end
    hs.each do |k,v|
      @rs.hmset(k, *v)
    end
    puts "relation set ok"

    @us.keys.each do |user_id|
      query = <<SQL
SELECT user_id, owner_id, DATE(created_at) AS date, MAX(created_at) as updated
FROM footprints
WHERE user_id = ?
GROUP BY user_id, owner_id, DATE(created_at)
ORDER BY updated DESC
LIMIT 50
SQL
      db.xquery(query, user_id).each do |fp|
        @fs.zadd(user_id, fp[:updated].to_i, "#{fp[:owner_id]}##{fp[:date]}")
      end
    end
    puts "footprints set ok"

    @us.keys.each do |user_id|
      friends_page(user_id)
    end
    puts "friendpage pre-render ok"

    @redis.save
    o, e, s = Open3.capture3("/bin/bash -c '/usr/bin/sudo cp /var/lib/redis/dump.rdb /var/lib/redis/backup.rdb'")
    puts "redis dump backup done!!"

    "#{o}\n#{e}\n#{s}"
  end


end


$stdout.sync = true
