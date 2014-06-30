require 'rubygems'
require 'sinatra'
require 'mixpanel-ruby'

require 'open-uri'
require 'nokogiri'
require 'rss'

require 'pry'
require 'awesome_print'
require 'uuid'
require 'atom'

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
  # TODO: Set unique user IDs for Mixpanel tracking.
  @mixpanel.track('1', 'view-procurement')
  generate_xml('483')
end

get '/bids/watershed.xml' do
  @mixpanel.track('1', 'view-watershed')
  generate_xml('486')
end

get '/bids/public-works.xml' do
  @mixpanel.track('1', 'view-public-works')
  generate_xml('484')
end

get '/bids/general-funds.xml' do
  @mixpanel.track('1', 'view-general-funds')
  generate_xml('482')
end

def generate_xml(category)
  # XPaths yanked from WebKit. w00t.
  xpaths = {
    # Watershed RFPs
    '486' => {  xpath: %{//*[@id="ctl00_content_Screen"]/table/tbody/tr[1]/td[1]/table[contains_text(., 'Award')]},
                name: 'Watershed RFPs' },
    '484' => { xpath: %{//*[@id="ctl00_content_Screen"]/table[2]/tbody/tr/td[1]/table[contains_text(., 'Award')]},
                name: 'Public Works RFPs'},
    '482' => { xpath: %{//*[@id="ctl00_content_Screen"]/table[contains_text(., 'Award')]},
                name: 'General Funds RFPs' },
    '483' => { xpath: %{//*[@id="ctl00_content_Screen"]/table[contains_text(., 'Award')]},
               name: 'Procurement RFPs'}
  }

  return unless category

  doc = Nokogiri::HTML(open("http://www.atlantaga.gov/index.aspx?page=#{ category }")).remove_namespaces!
  bid_table = doc.xpath(xpaths[category][:xpath], AttributeFilter.new)

  @bid_opportunities = []

  bid_table.each do |bid|
    _bid = {}

    # Try a few things to get the project number.
    _bid[:project_id] = bid.xpath(".//tr[contains_text(., 'Project number')]/td[2]", AttributeFilter.new)[0].content

    # Project name
    # For 483, there is no project number set out separately.
    project_name = bid.xpath(".//tr[contains_text(., 'Project name')]/td[2]", AttributeFilter.new)[0]
    if project_name != nil
      _bid[:name] = project_name.content
    end

    # Set up enclosures...!
    _enclosures = bid.xpath(".//a")
    @enclosures = []

    _enclosures.each do |enclosure|
      _enclosure = {}
      _enclosure[:name] = enclosure.content

      if enclosure["href"] && enclosure["href"].to_s.include?("mailto:")
        _enclosure[:href] = enclosure["href"][7, enclosure["href"].length]
      elsif enclosure["href"]
        _enclosure[:href] = "http://atlantaga.gov/#{ enclosure["href"] }"
      end

      @enclosures << _enclosure
    end

    _last = @enclosures.last

    if _last[:href].include?("@atlantaga.gov")
      _bid[:contracting_officer] = @enclosures.pop
    end

    _bid[:enclosures] = @enclosures

    @bid_opportunities << _bid
  end

  atom = Atom::Feed.new do |feed|
    feed.id = "urn:uuid:#{ UUID.new.generate }"
    feed.title = "City of Atlanta - Department of Procurement"
    feed.updated = Time.now.strftime("%Y-%m-%dT%H:%M:%SZ")
    feed.authors << Atom::Person.new(name: "Department of Procurement", email: "tiffani+DOP@codeforamerica.org")
    feed.generator = Atom::Generator.new(name: "Supply", version: "1.0", uri: "http://atlantaga.gov/procurement")
    feed.categories << Atom::Category.new(label: "#{ xpaths[category][:name] }", term: "#{ xpaths[category][:name] }")
    feed.rights = "Unless otherwise noted, the content, data, and documents offered through this ATOM feed are public domain and made available with a Creative Commons CC0 1.0 Universal dedication. https://creativecommons.org/publicdomain/zero/1.0/"

    @bid_opportunities.each do |bid_opp|
      if bid_opp[:contracting_officer]
        contracting_officer = Atom::Person.new(name: bid_opp[:contracting_officer][:name], email: bid_opp[:contracting_officer][:href])
      end

      feed.entries << Atom::Entry.new do |entry|
        entry.id = "urn:uuid:#{ UUID.new.generate }"
        entry.title = "#{ bid_opp[:project_id] } - #{ bid_opp[:name].to_s }"

        bid_opp[:enclosures].each do |enclosure|
          _enclosure = Atom::Link.new(title: enclosure[:name], href: enclosure[:href], rel: "enclosure", type: "application/pdf")
          entry.links << _enclosure
        end

        entry.authors << contracting_officer
        entry.updated = Time.now.strftime("%Y-%m-%dT%H:%M:%SZ")
        entry.summary = "A bid announcement for #{ bid_opp[:name] }."
      end
    end
  end

  #File.open("/Users/tiffani/Desktop/rss-procurement.xml", "w") { |f| f.write(atom.to_xml)}

  atom.to_xml
end
