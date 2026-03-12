# frozen_string_literal: true

namespace :api do
  desc "Generate API route list under docs/api_routes.md"
  task docs: :environment do
    require "fileutils"
    require "time"

    output = Rails.root.join("docs", "api_routes.md")
    FileUtils.mkdir_p(output.dirname)

    rows = []
    Rails.application.routes.routes.each do |route|
      controller = route.defaults[:controller]
      action = route.defaults[:action]
      next if controller.nil? || action.nil?
      next unless controller.start_with?("api/")

      verb = route.verb
      verb = verb.is_a?(Regexp) ? verb.source : verb.to_s
      verb = verb.gsub("^", "").gsub("$", "")
      path = route.path.spec.to_s
      rows << [ verb, path, "#{controller}##{action}" ]
    end

    rows.sort_by! { |verb, path, _| [ path, verb ] }

    content = +"# API Routes\n\n"
    content << "Generated at: #{Time.now.utc.iso8601}\n\n"
    content << "| Method | Path | Action |\n"
    content << "|---|---|---|\n"
    rows.each do |verb, path, action|
      content << "| `#{verb}` | `#{path}` | `#{action}` |\n"
    end

    File.write(output, content)
    puts "Wrote #{output}"
  end
end
