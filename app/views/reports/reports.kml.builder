xml.kml("xmlns" => "http://earth.google.com/kml/2.2", 
    "xmlns:atom" => "http://www.w3.org/2005/Atom") do
  xml.tag! "Document" do
    xml.name "#votereport"
    xml.description "Voting Reports for the 2008 election"
    xml.atom :link, :href => formatted_reports_path(:format => "atom", :only_path => false ), :rel => "alternate", :type => "application/atom+xml"
    xml.atom :link, :href => url_for(:controller => :reports, :only_path => false ), :rel => "alternate", :type => "text/html"
    xml.tag! "Folder" do
      xml.tag! "LookAt" do # look at the bounds of the US (approximately)
        xml.longitude -94.58
        xml.latitude 39.09
        xml.altitude 100
        xml.range 5000
        xml.tilt 0
        xml.heading 0
      end
      xml.open 1
      @reports.each do |report| # render :partial => @reports - doesn't work in builder?
        xml.tag! "Placemark", :id => "votereport:report:#{report.id}" do
          xml.name report.name
          xml.description "#{h(report.text)} in #{h(report.location.address)}"
          xml.tag! "Style" do
            xml.tag! "IconStyle" do
              xml.tag! "Icon" do
                xml.href report.twitter_user.profile_image_url if report.twitter_user
              end
            end
            xml.tag! "LabelStyle" do
              xml.color "ff00aaff"
            end
            xml.tag! "BalloonStyle" do
              xml.text "$[description]"
              xml.textColor "ff000000"
              xml.color "ff669999"
            end
          end
          xml.atom :author do
            xml.atom :name, report.twitter_user.name
          end if report.twitter_user
          xml.atom( :link, :href => report_url(:id => report, :only_path => false ), :rel => "alternate", :type => "text/html")
          xml.tag! "ExtendedData" do
            %w{wait_time}.each do |attribute|
              xml.tag! "Data", :name => attribute do
                xml.value report.send(attribute) 
              end
            end
          end
          xml.address report.location.address unless report.location.address.blank?          
          xml.tag! "TimeStamp" do
            xml.when report.created_at.iso8601
          end unless report.created_at.nil?
          xml << report.location.point.as_kml
        end        
      end
     end
  end
end
