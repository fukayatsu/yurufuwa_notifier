require 'nokogiri'
require 'faraday'
require 'redis-namespace'
require 'dotenv'; Dotenv.load
require 'json'
require 'gcm'
require 'tapp'

class Notifier
  def fetch_and_send
    res = pplog_client.get '/'
    html_doc = Nokogiri::HTML(res.body)
    current_user_name = html_doc.css('[data-current-user-nickname]')
      .attr('data-current-user-nickname').value.gsub('@', '')
    posts    = html_doc.css('.post-index')
    my_post  = posts.first

    created_at = Time.parse(my_post.css('.created-at').text)
    title     = my_post.css('.title').text.strip
    if redis[:my_post_created_at] != created_at.to_i.to_s
      redis[:my_post_created_at]   = created_at.to_i.to_s
      redis.del(:stared_list)
    end

    my_post.css('.star-content').each do |star_content|
      user_icon = star_content.css('img').attr('src').value
      user_name = star_content.css('[data-user-nickname]').attr('data-user-nickname').value

      next if redis.sismember(:stared_list, user_name)
      redis.sadd(:stared_list, user_name)
      send_notification({
        user_name: user_name,
        user_icon: user_icon,
        title:     title,
        action:    "read_poem",
        message:   "@#{user_name} があしあとをつけました",
        url:       "https://www.pplog.net/u/#{current_user_name}",
      })
    end

    posts[1..-1].each do |post|
      created_at = Time.parse(post.css('.created-at').text)
      user_id    = post.attr('id')
      user_name  = post.css('.post-info > .user-name').text.gsub('@', '')
      user_icon  = post.css('img').attr('src').value
      title      = post.css('.title').text.strip

      if redis[user_id] != created_at.to_i.to_s
        redis.setex(user_id, 60*60*24*10, created_at.to_i.to_s)
        send_notification({
          user_name: user_name,
          user_icon: user_icon,
          title:     title,
          action:    "new_poem",
          message:   "@#{user_name} がポエみました#{rand(0..10) == 0 ? ' ( ˘ω˘)' : ''}",
          url:       "https://www.pplog.net/u/#{user_name}",
        })
      end
    end
  end

private

  def pplog_client
    @pplog_client ||= Faraday.new(
      url: 'https://www.pplog.net',
      headers: {
        'Cookie'     => ENV['PPLOG_COOKIE'],
        'User-Agent' => 'yurufuwa android gcm test'
      }
    ) do |faraday|
      faraday.request  :url_encoded             # form-encode POST params
      faraday.response :logger                  # log requests to STDOUT
      faraday.adapter  Faraday.default_adapter  # make requests with Net::HTTP
    end
  end

  def send_notification(data)
    @gcm ||= GCM.new(ENV['GCM_API_KEY'])
    if !data[:user_icon].match(/^http/)
      data[:user_icon] = "http:#{data[:user_icon]}"
    end
    puts "[options]"
    options          = { data: data }.tapp
    registration_ids = [ENV['GCM_REG_ID']]
    puts "[response]"
    @gcm.send_notification(registration_ids, options).tapp
  end

  def redis
    return @redis if @redis

    if ENV["REDISTOGO_URL"]
      uri = URI.parse(ENV["REDISTOGO_URL"])
      redis = Redis.new(host: uri.host, port: uri.port, password: uri.password)
    else
      redis = Redis.new
    end

    @redis = Redis::Namespace.new(:yurufuwa_notifier, redis: redis)
  end
end