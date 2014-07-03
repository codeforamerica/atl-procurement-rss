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
  @mixpanel.track('1', 'Added Procurement feed')
  generate_xml('483')
end

get '/bids/watershed.xml' do
  @mixpanel.track('1', 'Added Watershed feed')
  generate_xml('486')
end

get '/bids/public-works.xml' do
  @mixpanel.track('1', 'Added Public Works feed')
  generate_xml('484')
end

get '/bids/general-funds.xml' do
  @mixpanel.track('1', 'Added General Funds feed')
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
    _bid[:project_id] = _bid[:project_id].strip if _bid[:project_id]

    # Project name
    # For 483, there is no project number set out separately.
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

      if enclosure["href"] && enclosure["href"].to_s.include?("mailto:")
        _enclosure[:href] = enclosure["href"][7, enclosure["href"].length]
      elsif enclosure["href"]
        _enclosure[:href] = "http://atlantaga.gov/#{ enclosure["href"] }"
      end

      # Some enclosures end up missing a 'title' element and are usually a duplicate
      # of a previously included file with all the right info included.
      @enclosures << _enclosure unless /\A[[:space:]]*\z/ === _enclosure[:name]
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
    feed.title = "City of Atlanta - #{ xpaths[category][:name] }"
    feed.updated = Time.now.strftime("%Y-%m-%dT%H:%M:%SZ")
    feed.authors << Atom::Person.new(name: "Department of Procurement", email: "tiffani+DOP@codeforamerica.org")
    feed.generator = Atom::Generator.new(name: "Supply", version: "1.0", uri: "http://atlantaga.gov/procurement")
    feed.categories << Atom::Category.new(label: "#{ xpaths[category][:name] }", term: "#{ xpaths[category][:name] }")
    feed.rights = "Unless otherwise noted, the content, data, and documents offered through this ATOM feed are public domain and made available with a Creative Commons CC0 1.0 Universal dedication. https://creativecommons.org/publicdomain/zero/1.0/"

    @bid_opportunities.each do |bid_opp|
      if bid_opp[:contracting_officer]
        # Clean up names
        name = bid_opp[:contracting_officer][:name].gsub(/(Mr|Mrs|Ms)\.*/i, "").gsub(/,\s+(Contracting Officer|Contract Administrator)/i, "").strip
        contracting_officer = Atom::Person.new(name: name, email: bid_opp[:contracting_officer][:href], uri: "http://atlantaga.gov/index.aspx?page=#{ category }")
      end

      feed.entries << Atom::Entry.new do |entry|
        entry.id = "urn:uuid:#{ UUID.new.generate }"
        entry.title = "#{ bid_opp[:project_id] } - #{ bid_opp[:name].to_s }"

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
        # TODO: Don't tie this date to when someone pulls the feed.
        entry.updated = Time.now.strftime("%Y-%m-%dT%H:%M:%SZ")
        # TODO: Beef up this summary.
        entry.summary = "A bid announcement for #{ bid_opp[:name] }."
      end
    end
  end

  #File.open("/Users/tiffani/Desktop/rss-procurement.xml", "w") { |f| f.write(atom.to_xml)}

  atom.to_xml
end
