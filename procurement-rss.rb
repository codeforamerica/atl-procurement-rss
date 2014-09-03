require 'rubygems'
require 'bundler/setup'

require 'sinatra'
require 'mixpanel-ruby'

require 'open-uri'
require 'nokogiri'

require 'pry'
require 'awesome_print'
require 'atom'

require 'active_record'
require 'sinatra/activerecord'

require 'base64'

class Page < ActiveRecord::Base
  scope :previous, ->(id, category) { where("id < ? AND category = ?", id, category)}
end

# Page IDs for scraping's sake!
PROCUREMENT_RFPS = '483'
WATERSHED_RFPS = '486'
PUBLIC_WORKS_RFPS = '484'
GENERAL_FUND_RFPS = '482'
AVIATION_RFPS = '21'

EMPTY_STR = /\A[[:space:]]*\z/
BLANK_STR = /\A[[:blank:]]*\z/

configure :development do
  set :database, "sqlite3:///atl-procurement-rss.db"
  set :show_exceptions, true
end

configure :test do
  set :database, "sqlite3:///atl-procurement-rss.db"
end

configure :production do
  db = URI.parse(ENV['DATABASE_URL'] || 'postgres:///localhost/atl-procurement-rss')

  ActiveRecord::Base.establish_connection(
    adapter: 'postgresql',
    host: db.host,
    username: db.user,
    password: db.password,
    database: db.path[1..-1],
    encoding: 'utf8'
  )
end

before do
  content_type :xml

  # Mixpanel token is set via 'heroku config:set MIXPANEL_TOKEN=whateverthetokenis'
  @mixpanel = Mixpanel::Tracker.new(ENV['MIXPANEL_TOKEN'])
end

class AttributeFilter
  # Since Nokogiri (by way of libxml) only supports XPath 1.0, we're missing
  # a lot of the more helpful functions. No worries, however!
  def contains_text node_set, text
    node_set.find_all { |node| node.to_s =~ /#{ text }/i }
  end
end

get '/bids/procurement.xml' do
  atom, page = generate_xml(PROCUREMENT_RFPS)

  etag(page.etag)
  last_modified(page.updated_at)
  atom
end

get '/bids/watershed.xml' do
  atom, page = generate_xml(WATERSHED_RFPS)

  etag(page.etag)
  last_modified(page.updated_at)
  atom
end

get '/bids/public-works.xml' do
  atom, page = generate_xml(PUBLIC_WORKS_RFPS)

  etag(page.etag)
  last_modified(page.updated_at)
  atom
end

get '/bids/general-funds.xml' do
  atom, page = generate_xml(GENERAL_FUND_RFPS)

  etag(page.etag)
  last_modified(page.updated_at)
  atom
end

get '/bids/aviation.xml' do
  atom, page = generate_xml(AVIATION_RFPS)

  etag(page.etag)
  last_modified(page.updated_at)
  atom
end

def generate_xml(category)
  # XPaths yanked from WebKit. w00t.
  xpaths = {
    # Watershed RFPs
    WATERSHED_RFPS => {  xpath: %{//*[@id="ctl00_content_Screen"]/table/tbody/tr[1]/td[1]/table[contains_text(., 'Award')]},
                name: 'Watershed RFPs' },
    PUBLIC_WORKS_RFPS => { xpath: %{//*[@id="ctl00_content_Screen"]/table[2]/tbody/tr/td[1]/table[contains_text(., 'Award')]},
                name: 'Public Works RFPs'},
    GENERAL_FUND_RFPS => { xpath: %{//*[@id="ctl00_content_Screen"]/table[contains_text(., 'Award')]},
                name: 'General Funds RFPs' },
    PROCUREMENT_RFPS => { xpath: %{//*[@id="ctl00_content_Screen"]/table[contains_text(., 'Award')]},
               name: 'Procurement RFPs'},
    AVIATION_RFPS => {
      xpath: %{//*[@id="ctl00_content_Screen"]/table/tbody/tr/td[1]/table[contains_text(., 'Award')]},
      name: 'Aviation RFPs'
    }
  }

  return unless category

  doc = Nokogiri::HTML(open("http://www.atlantaga.gov/index.aspx?page=#{ category }")).remove_namespaces!

  @previous_page = Page.where(category: category).last

  if @previous_page && Base64.encode64(@previous_page.content) == Base64.encode64(doc.to_s)
    @page = @previous_page
  else
    @page = Page.create(title: xpaths[category][:name], content: doc.to_s, category: category, etag: SecureRandom.uuid)
  end

  bid_table = doc.xpath(xpaths[category][:xpath], AttributeFilter.new)

  @bid_opportunities = []

  bid_table.each do |bid|
    _bid = {}

    # Try a few things to get the project number.
    if GENERAL_FUND_RFPS == category
      _bid[:project_id] = bid.xpath(".//tr[contains_text(., 'number')]/td[2]", AttributeFilter.new)[0].content
      _bid[:project_id] = _bid[:project_id].split(',')[0]
    elsif category != PROCUREMENT_RFPS
      _bid[:project_id] = bid.xpath(".//tr[contains_text(., 'Project number')]/td[2]", AttributeFilter.new)[0].content
      _bid[:project_id] = _bid[:project_id].strip if _bid[:project_id]
    end

    # Project name
    project_name = bid.xpath(".//tr[contains_text(., 'Name')]/td[2]", AttributeFilter.new)[0]

    if project_name != nil
      _bid[:name] = project_name.content
    end

    _bid[:name] = _bid[:name].strip if _bid[:name]

    _bid[:due_date] = bid.xpath(".//tr[contains_text(., 'Due date')]/td[2]", AttributeFilter.new)
    _bid[:prebid_conf_date] = bid.xpath(".//tr[contains_text(., '(PRE-BID|PRE-PROPOSAL) CONFERENCE DATE\s*\/\s*TIME')]/td[2]", AttributeFilter.new)
    _bid[:prebid_conf_location] = bid.xpath(".//tr[contains_text(., '(PRE-BID|PRE-PROPOSAL) CONFERENCE LOCATION\.*')]/td[2]", AttributeFilter.new)

    _bid[:site_visit_info] = bid.xpath(".//tr[contains_text(., 'SITE.*VISIT.*DATE')]", AttributeFilter.new)
    _bid[:site_visit_location] = bid.xpath(".//tr[contains_text(., 'SITE.*VISIT.*LOCATION')]", AttributeFilter.new)

    # Set up enclosures...!
    _enclosures = bid.xpath(".//a")
    @enclosures = []

    _enclosures.each do |enclosure|
      _enclosure = {}
      _enclosure[:name] = enclosure.content

      unless BLANK_STR === _enclosure[:name]
        if enclosure["href"] && enclosure["href"].to_s.include?("mailto:")
          _enclosure[:href] = enclosure["href"][7, enclosure["href"].length]
          _bid[:contracting_officer] = _enclosure
        elsif enclosure["href"].to_s.include?("showdocument.aspx")
          _enclosure[:href] = "http://www.atlantaga.gov/#{ enclosure["href"] }"

          # Some enclosures end up missing a 'title' element and are usually a duplicate
          # of a previously included file with all the right info included.
          @enclosures << _enclosure unless EMPTY_STR === _enclosure[:name]
        end
      end
    end

    _bid[:enclosures] = @enclosures

    @bid_opportunities << _bid
  end

  atom = Atom::Feed.new do |feed|
    feed.id = "urn:uuid:#{ SecureRandom.uuid }"
    feed.title = "City of Atlanta - #{ xpaths[category][:name] }"
    feed.updated = @last_modified
    feed.authors << Atom::Person.new(name: "Department of Procurement", email: "tiffani+DOP@codeforamerica.org")
    feed.generator = Atom::Generator.new(name: "Supply", version: "1.0", uri: "http://www.atlantaga.gov/procurement")
    feed.categories << Atom::Category.new(label: "#{ xpaths[category][:name] }", term: "#{ xpaths[category][:name] }")
    feed.rights = "Unless otherwise noted, the content, data, and documents offered through this ATOM feed are public domain and made available with a Creative Commons CC0 1.0 Universal dedication. https://creativecommons.org/publicdomain/zero/1.0/"

    @bid_opportunities.each do |bid_opp|
      if bid_opp[:contracting_officer]
        # Clean up names
        name = bid_opp[:contracting_officer][:name].gsub(/(Mr|Mrs|Ms)\.*/i, "").gsub(/,\s+(Contracting Officer|Contract Administrator)/i, "").strip
        contracting_officer = Atom::Person.new(name: name, email: bid_opp[:contracting_officer][:href], uri: "http://www.atlantaga.gov/index.aspx?page=#{ category }")
      elsif !bid_opp.has_key?(:contracting_officer)
        name = "Department of Procurement"
        contracting_officer = Atom::Person.new(name: name, email: "kbrooks@atlantaga.gov", uri: "http://www.atlantaga.gov/index.aspx?page=#{ category }")
      end

      feed.entries << Atom::Entry.new do |entry|
        entry.id = "urn:uuid:#{ SecureRandom.uuid }"

        if category != PROCUREMENT_RFPS
          entry.title = "#{ bid_opp[:project_id] } - #{ bid_opp[:name].to_s }"
        else
          entry.title = bid_opp[:name].to_s
        end

        unless bid_opp[:site_visit_info].empty?
          site_visits = bid_opp[:site_visit_info].collect do |svi|
            %Q{<li><strong>#{ svi.xpath(".//td[1]")[0].content.split.map(&:capitalize).join(' ') }:</strong> #{ svi.xpath(".//td[2]")[0].content }</li>}
          end
        end

        unless bid_opp[:site_visit_location].empty?
          site_visit_locations = bid_opp[:site_visit_location].collect do |svl|
            %Q{<li><strong>#{ svl.xpath(".//td[1]")[0].content.split.map(&:capitalize).join(' ') }:</strong> #{ svl.xpath(".//td[2]")[0].content }</li>}
          end
        end

        entry_content = %Q{
          <p>
            A bid announcement for #{ bid_opp[:name] }.
          </p>
          <p>
            <strong>Important dates:</strong><br />
            <ul>
              #{ "<li><strong>Pre-bid conference date:</strong> #{ bid_opp[:prebid_conf_date][0].content }</li>" unless bid_opp[:prebid_conf_date].empty? }
              #{ "<li><strong>Pre-bid conference location:</strong> #{ bid_opp[:prebid_conf_location][0].content }</li>" unless bid_opp[:prebid_conf_location].empty? }
              #{ "<li><strong>Proposal due date:</strong> #{ bid_opp[:due_date][0].content }</li>" unless bid_opp[:due_date].empty? }
              #{ site_visits.join if site_visits }
              #{ site_visit_locations.join if site_visit_locations }
            </ul>
          </p>
          <p>
            <strong>Included files:</strong><br />
            <ol>
              #{ bid_opp[:enclosures].collect { |enclosure| %{<li><a href="#{ enclosure[:href] }">#{ enclosure[:name] }</a> (PDF)</li>} }.join }
            </ol>
          </p>
        }

        entry.content = Atom::Content::Html.new(entry_content)

        bid_opp[:enclosures].each do |enclosure|
          _enclosure = Atom::Link.new(title: enclosure[:name], href: enclosure[:href], rel: "enclosure", type: "application/pdf")
          entry.links << _enclosure
        end

        entry.authors << contracting_officer
        # TODO: Beef up this summary.
        entry.summary = "A bid announcement for #{ bid_opp[:name] }."
      end
    end
  end

  # If nothing's changed between page comparisons (with a very naive Base64-based comparison), say so with 304.
  [atom.to_xml, @page]
end
