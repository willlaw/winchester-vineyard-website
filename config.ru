require 'sinatra'
require 'sass'
require 'builder'

require 'dalli'
require 'rack-cache'
require 'active_support/core_ext/time/calculations'

#
# Defined in ENV on Heroku. To try locally, start memcached and uncomment:
# ENV["MEMCACHE_SERVERS"] = "localhost"
if memcache_servers = ENV["MEMCACHE_SERVERS"]
  use Rack::Cache,
    verbose: true,
    metastore:   "memcached://#{memcache_servers}",
    entitystore: "memcached://#{memcache_servers}"

  # Flush the cache
  Dalli::Client.new.flush
end

set :static_cache_control, [:public, max_age: 1800]

before do
  cache_control :public, max_age: 1800  # 30 mins
end

require 'httparty'

CHURCHAPP_HEADERS = {"Content-type" => "application/json", "X-Account" => "winvin", "X-Application" => "Group Slideshow", "X-Auth" => ENV['CHURCHAPP_AUTH']}

helpers do
  def protect!
    unless authorized?
      response['WWW-Authenticate'] = %(Basic realm="Restricted Area")
      throw(:halt, [401, "Not authorized\n"])
    end
  end
  def authorized?
    @auth ||=  Rack::Auth::Basic::Request.new(request.env)
    username = ENV['GROUPS_SIGNUP_USERNAME']
    password = ENV['GROUPS_SIGNUP_PASSWORD']
    @auth.provided? && @auth.basic? && @auth.credentials && @auth.credentials == [username, password]
  end

  def fetch_events(page)
    response = HTTParty.get("https://api.churchapp.co.uk/v1/calendar/events?page=#{page}", headers: CHURCHAPP_HEADERS)
    JSON.parse(response.body)["events"].map { |e| Event.new(e) }
  end
end

get '/' do
  events = (fetch_events(1) + fetch_events(2) + fetch_events(3))
  @featured_events = events.select(&:featured?)
  @healing_events = events.select { |e| e.category == 'Healing' }
  haml :index
end

get '/groups-list/?' do
  response = HTTParty.get('https://api.churchapp.co.uk/v1/smallgroups/groups?view=active', headers: CHURCHAPP_HEADERS)
  @groups = JSON.parse(response.body)["groups"].map { |g| Group.new(g) }
  haml :groups_list, layout: nil
end

get '/groups-slideshow/?' do
  response = HTTParty.get('https://api.churchapp.co.uk/v1/smallgroups/groups?view=active', headers: CHURCHAPP_HEADERS)
  @groups = JSON.parse(response.body)["groups"].map { |g| Group.new(g) }
  haml :groups, layout: nil
end


get '/groups-signup/?' do
  redirect 'https://winchester-vineyard.herokuapp.com/groups-signup' unless request.secure?
  protect!
  response = HTTParty.get('https://api.churchapp.co.uk/v1/addressbook/contacts?per_page=400', headers: CHURCHAPP_HEADERS)
  @contacts = JSON.parse(response.body)["contacts"]

  response = HTTParty.get('https://api.churchapp.co.uk/v1/smallgroups/groups?view=active', headers: CHURCHAPP_HEADERS)
  @groups = JSON.parse(response.body)["groups"].map { |g| Group.new(g) }

  haml :groups_signup, layout: nil
end

post '/groups-signup/:group_id/:contact_id' do |group_id, contact_id|
  halt 426 unless request.secure?
  body = {
    "action" => "add",
    "members" => {
      "contacts" => [ contact_id.to_i ],
    }
  }.to_json
  url = 'https://api.churchapp.co.uk/v1/smallgroups/group/'+group_id+'/members'
  puts body, url
  response = HTTParty.post(url, headers: CHURCHAPP_HEADERS, body: body)
  puts response.body
  response.code
end

helpers do
  def secs_until(n)
    Time.parse(n['datetime']) - Time.now
  end
end

SECONDS_IN_A_DAY = 86400
SECONDS_IN_A_WEEK = 86400 * 7

get '/feed.xml' do
  require 'firebase'

  firebase = Firebase::Client.new('https://winvin.firebaseio.com/')
  all = firebase.get('news').body.values

  soon = all.select do |n|
    secs_until(n) >= 0 && secs_until(n) < SECONDS_IN_A_DAY
  end
  soon.each do |n|
    n['id'] += '-soon'
    n['pubDate'] = Time.parse(n['datetime']) - SECONDS_IN_A_DAY
  end

  upcoming = all.select do |n|
    secs_until(n) >= SECONDS_IN_A_DAY && secs_until(n) < SECONDS_IN_A_WEEK
  end
  upcoming.each do |n|
    n['id'] += '-upcoming'
    n['pubDate'] = Time.parse(n['datetime']) - SECONDS_IN_A_WEEK
  end

  @news = soon + upcoming

  builder :news
end

class Talk
  attr :full_name, :who, :date, :download_url, :slides_url, :id, :slug, :series_name, :title

  def initialize(hash)
    @id = hash['id']
    @series_name = hash['series_name']
    @full_name = (hash['series_name'].present? ? "[" + hash['series_name'] + "] " : "" ) + hash['title']
    @who = hash['who']
    @date = Time.parse(hash['datetime'])
    @download_url = hash['download_url']
    @slides_url = hash['slides_url']
    @published = hash['published']
    @slug = hash['slug']
    @title = hash['title']
  end

  def part_of_a_series?
    @series_name.present?
  end

  def has_slides?
    @slides_url.present?
  end

  def long_title
    [
      @date.strftime("%a %d %b %Y"),
      ": ",
      @full_name,
      " (",
      @who,
      ")"
    ].join
  end

  def description
    "Given by #{@who} on #{@date.strftime("%a %d %b %y")}."
  end

  def published?
    !!@published
  end
end

Group = Struct.new(:hash) do
  def visible?
    hash["embed_visible"] == "1"
  end

  def id
    hash["id"]
  end

  def full?
    signup? && spaces <= 0
  end

  def signup?
    !!hash["signup_capacity"]
  end

  def image?
    !hash["images"].empty?
  end

  def location?
    !hash["location"].empty?
  end

  def first_sentence
    hash["description"].match(/^(.*?)[.?!]\s/)
  end

  def address
    hash["location"]["address"]
  end

  def image
    hash["images"]["square_500"]
  end

  def spaces
    if signup?
      hash["signup_capacity"].to_i - hash["no_members"].to_i
    end
  end

  def day
    if (hash["day"].nil?)
      "TBC"
    else
      %w(Sundays Mondays Tuesdays Wednesdays Thursdays Fridays Saturdays)[hash["day"].to_i]
    end
  end

  def time
    hash["time"]
  end

  def name
    hash["name"].sub(/\(.*201.\)/, '')
  end
end

Event = Struct.new(:hash) do
  def featured?
    hash["signup_options"]["public"]["featured"] == "1"
  end

  def category
    hash["category"]["name"]
  end

  def name
    hash["name"]
  end

  def ticket_url
    hash["signup_options"]["tickets"]["url"]
  end

  def image?
    !hash["images"].empty?
  end

  def image_url
    hash["images"]["original_500"]
  end

  def start_time
    Time.parse(hash["datetime_start"])
  end

  def start_date
    start_time.midnight
  end

  def end_time
    Time.parse(hash["datetime_end"])
  end

  def end_date
    end_time.midnight
  end

  def end_date_string
    end_date.strftime("%d %b")
  end

  def start_date_string
    start_date.strftime("%d %b")
  end

  def start_time_string
    start_time.strftime("%H:%M")
  end

  def end_time_string
    end_time.strftime("%H:%M")
  end

  def full_date_string
    if self.start_date != self.end_date
      "#{self.start_date_string} - #{self.end_date_string}"
    else
      "#{self.start_date_string} #{self.start_time_string} - #{self.end_time_string}"
    end
  end

  def location?
    hash["location"].size > 0
  end

  def location_url
    "http://maps.google.co.uk/?q=" + hash["location"]["address"] rescue nil
  end

  def location_title
    hash["location"]["name"]
  end
end

get '/talks/:slug' do |slug|
  require 'firebase'
  firebase = Firebase::Client.new('https://winvin.firebaseio.com/')
  talk_id = firebase.get('talks-by-slug/' + slug ).body
  halt 404 if (talk_id.nil?)
  @talk = Talk.new(firebase.get('talks/' + talk_id).body)
  halt 404 unless @talk.published?
  @og_url = 'http://winvin.org.uk/talks/' + slug
  @og_title = "Winchester Vineyard Talk: #{@talk.full_name}"
  @og_description = @talk.description
  haml :talk
end

helpers do
  def get_talks
    require 'firebase'
    firebase = Firebase::Client.new('https://winvin.firebaseio.com/')
    firebase.get('talks').body.values.map {|t| Talk.new(t) }.sort_by(&:date).reverse
  end
end

get '/audio_plain' do
  @talks = get_talks
  haml :audio, :layout => false
end

get '/audio.xml' do
  @talks = get_talks
  builder :audio
end

get '/students/?' do
  haml :students
end

get '/welcome/?' do
  @talks = get_talks.select(&:published?).select {|t| t.series_name == "What on earth is the Vineyard" }
  haml :welcome
end

get '/lifegroups/?' do
  haml :lifegroups
end

get '/adventconspiracy/?' do
  haml :adventconspiracy
end


get '/css/styles.css' do
  scss :styles, :style => :expanded
end

get('/node/168/?') { redirect '/#wv-news' }
get('/node/2/?') { redirect '/#wv-sundays' }
get('/node/319/?') { redirect '/#wv-team' }
get('/node/74/?') { redirect '/#wv-growing' }

get '/node/?*' do
  redirect '/'
end

not_found do
  status 404
  haml :not_found
end


get('/groupsslideshow/?') { redirect '/groups-slideshow/' }

get('/feedback/?') { redirect 'https://docs.google.com/forms/d/10iS6tahkIYb_rFu1uNUB9ytjsy_xS138PJcs915qASo/viewform?usp=send_form' }

get('/data-protection-policy/?') { redirect 'https://s3-eu-west-1.amazonaws.com/winchester-vineyard-website-assets/uploads/data-protection-policy.pdf' }

get('/makingithappen/?') { redirect 'https://docs.google.com/forms/d/12LKbZo-FXRk5JAPESu_Zfog7FAtCXtdMAfdHCbQ8OXs/viewform?c=0&w=1' }
get('/requestasozo/?') { redirect 'https://docs.google.com/forms/d/16l71KEmGGhZar84lQIMpkcZuR6bVxlzGB8r0-cSni7s/viewform?fbzx=-1795998873449154632' }

get('/connect/?') { redirect '/welcome' }

get('/landing-banner-code/?') { redirect '/students' }

get('/find-us/?') { redirect '/#wv-find-us' }
get('/camp/?') { redirect 'https://winvin.churchapp.co.uk/events/vqh8emhs' }
get('/summerschool16/?') { redirect 'https://winvin.churchapp.co.uk/events/7naoumvy' }
get('/bbq/?') { redirect 'https://winvin.churchapp.co.uk/events/rqtp4nfc' }

get('/focus-on-kids/?') { redirect 'https://winchester-vineyard-website-assets.s3.amazonaws.com/assets/Focus%20on%20Kids%20and%20Youth%20Vision.pdf' }

get '/audio/?*' do
  redirect '/#wv-talks'
end


get('/events/?') { redirect '/#wv-news' }
get('/donate/?') { redirect 'https://winvin.churchapp.co.uk/donate/' }

run Sinatra::Application
