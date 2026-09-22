require "json"
require "net/http"

# Seeds a freshly-booted, disposable robot-notes server with fictional
# sample content for App Store screenshot capture: a handful of notes plus
# one sample database with a few rows.
class ScreenshotSeed
  NOTES = [
    {
      title: "Weeknight dinner ideas",
      path: "Personal",
      content: <<~MD,
        # Weeknight dinner ideas

        - [ ] Sheet-pan salmon with asparagus
        - [ ] Chickpea and spinach curry
        - [x] Turkey chili (freezer batch)
        - [ ] Soba noodles with peanut sauce

        Pick two for this week and add the missing groceries to the list.
      MD
    },
    {
      title: "Team sync — planning notes",
      path: "Work",
      content: <<~MD,
        # Team sync — planning notes

        **Attendees:** Priya, Sam, Jonas

        ## Decisions
        - Ship the search redesign behind a flag first
        - Push the migration doc to next week

        ## Follow-ups
        1. Priya: draft the flag rollout plan
        2. Sam: file the migration doc as a note here
      MD
    },
    {
      title: "Trip to Lisbon",
      path: "Personal/Travel",
      content: <<~MD,
        # Trip to Lisbon

        ## Must-see
        - Alfama at sunset
        - LX Factory on a Saturday
        - Day trip to Sintra

        ## Notes to self
        Book the Sintra train tickets in advance — they sell out on weekends.
      MD
    },
    {
      title: "Reading notes: Deep Work",
      path: "Reading",
      content: <<~MD,
        # Reading notes: *Deep Work*

        > "The ability to perform deep work is becoming increasingly rare
        > at exactly the same time it is becoming increasingly valuable."

        Key takeaway: schedule deep work like a meeting, don't wait for
        it to happen on its own.
      MD
    },
  ].freeze

  DATABASE = {
    title: "Reading list",
    path: "Reading",
    properties: {
      "status" => {type: "select", label: "Status", options: %w[To-read Reading Finished]},
      "rating" => {type: "number", label: "Rating"},
      "favorite" => {type: "checkbox", label: "Favorite"},
    },
    views: [
      {name: "All books", type: "table"},
    ],
    rows: [
      {title: "Deep Work", properties: {"status" => "Finished", "rating" => 5, "favorite" => true}},
      {title: "The Pragmatic Programmer", properties: {"status" => "Reading", "rating" => 4, "favorite" => false}},
      {title: "Project Hail Mary", properties: {"status" => "To-read"}},
    ],
  }.freeze

  def initialize(base_url:, api_key:, ui: nil)
    @base_url = base_url
    @api_key = api_key
    @ui = ui
  end

  # Creates every sample note and the sample database (with its rows).
  # Raises on the first request that doesn't come back 2xx.
  def seed!
    NOTES.each { |note| post!("/notes", title: note[:title], path: note[:path], content: note[:content]) }

    database = post!(
      "/databases",
      title: DATABASE[:title],
      path: DATABASE[:path],
      properties: DATABASE[:properties],
      views: DATABASE[:views],
    )
    database_id = database.fetch("id")
    DATABASE[:rows].each do |row|
      post!("/databases/#{database_id}/rows", title: row[:title], properties: row[:properties])
    end
  end

  private

  def post!(path, body)
    uri = URI("#{@base_url}#{path}")
    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{@api_key}"
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body)

    message("Seeding #{path} (#{body[:title]})...")
    response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
    unless response.is_a?(Net::HTTPSuccess)
      raise "seeding #{path} failed: #{response.code} #{response.body}"
    end

    JSON.parse(response.body)
  end

  def message(text)
    @ui ? @ui.message(text) : puts(text)
  end
end
