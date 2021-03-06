require 'rubygems'
require 'trollop'

opts = Trollop::options do
    banner <<-EOS
Create ObservationLinks for observations that have been integrated into 
Globi.

Usage:

  rails runner tools/globi_observation_links.rb URL

where [options] are:
EOS
  opt :debug, "Print debug statements", :type => :boolean, :short => "-d"
end

start_time = Time.now
new_count = 0
old_count = 0
delete_count = 0
href_name = "GloBI (EOL)"

url = ARGV[0]
# url = "https://raw.githubusercontent.com/jhpoelen/backwarden/master/provider-consumer.csv"
Trollop::die "You must specify URL where we can retrieve the mappings" if url.blank?
CSV.foreach(open(url), headers: true) do |row|
  observation_id = row['provider'].to_s[/\/(\d+)$/, 1]
  observation = Observation.find_by_id(observation_id)
  if observation.blank?
    puts "\tobservation #{observation_id} doesn't exist, skipping..."
    next
  end
  href = row['consumer']
  if href.blank?
    puts "\tGloBI / EOL URL missing, skipping..."
    next
  end
  existing = ObservationLink.where(observation_id: observation_id, href: href).first
  if existing
    existing.touch unless opts[:debug]
    old_count += 1
    puts "\tobservation link already exists, skipping"
  else
    ol = ObservationLink.new(:observation => observation, :href => href, :href_name => href_name, :rel => "alternate")
    ol.save unless opts[:debug]
    new_count += 1
    puts "\tCreated #{ol}"
  end
end

delete_count = ObservationLink.where(href_name: href_name).where("updated_at < ?", start_time).count
ObservationLink.where("href_name = ? AND updated_at < ?", href_name, start_time).delete_all unless opts[:debug]

puts "#{new_count} created, #{old_count} updated, #{delete_count} deleted in #{Time.now - start_time} s"
