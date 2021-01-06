require "json"
require "dependabot/file_fetchers"
require "dependabot/file_parsers"
require "dependabot/update_checkers"
require "dependabot/file_updaters"
require "dependabot/pull_request_creator"
require "dependabot/omnibus"

# Full name of the repo you want to create pull requests for.
organization = ENV["ORGANIZATION"]
project = ENV["PROJECT"]
repository = ENV["REPOSITORY"]
repo_name = "#{organization}/#{project}/_git/#{repository}"

# Directory where the base dependency files are.
directory = ENV["DIRECTORY"] || "/"

# Branch against which to create PRs
branch = ENV["TARGET_BRANCH"] || nil

# Name of the package manager you'd like to do the update for. Options are:
# - bundler
# - pip (includes pipenv)
# - npm_and_yarn
# - maven
# - gradle
# - cargo
# - hex
# - composer
# - nuget
# - dep
# - go_modules
# - elm
# - submodules
# - docker
# - terraform
package_manager = ENV["PACKAGE_MANAGER"] || "bundler"

# GitHub native implementation modifies some of the names in the config file
# https://docs.github.com/en/github/administering-a-repository/configuration-options-for-dependency-updates#package-ecosystem
PACKAGE_ECOSYSTEM_MAPPING = { # [Hash<String, String>]
  "npm" => "npm_and_yarn",
  "yarn" => "npm_and_yarn",
  "pipenv" => "pip",
  "pip-compile" => "pip",
  "poetry" => "pip",
  "gomod" => "go_modules",
  "gitsubmodule" => "submodules",
  "mix" => "hex"
}.freeze
package_manager = PACKAGE_ECOSYSTEM_MAPPING.fetch(package_manager, package_manager)

##########################################################
# Setup the versioning strategy (a.k.a. update strategy) #
##########################################################
versioning_strategy = ENV['VERSIONING_STRATEGY'] || "auto"
# GitHub native implementation modifies some of the names in the config file
VERSIONING_STRATEGIES = { # [Hash<String, Symbol>]
  "auto" => :auto,
  "lockfile-only" => :lockfile_only,
  "widen" => :widen_ranges,
  "increase" => :bump_versions,
  "increase-if-necessary" => :bump_versions_if_necessary
}.freeze
update_strategy = VERSIONING_STRATEGIES.fetch(versioning_strategy, versioning_strategy)

#################################
# Setup the hostname to be used #
#################################
azure_hostname = ENV["AZURE_HOSTNAME"] || "dev.azure.com"
puts "Using '#{azure_hostname}' as hostname"

#####################################
# Setup credentials for source code #
#####################################
system_access_token = ENV["SYSTEM_ACCESSTOKEN"]
credentials = [{
  "type" => "git_source",
  "host" => azure_hostname,
  "username" => "x-access-token",
  "password" => system_access_token
}]

########################################################
# Add GitHub Access Token (PAT) to avoid rate limiting #
########################################################
if ENV["GITHUB_ACCESS_TOKEN"]
  puts "GitHub access token has been provided."
  credentials << {
    "type" => "git_source",
    "host" => "github.com",
    "username" => "x-access-token",
    "password" => ENV["GITHUB_ACCESS_TOKEN"] # A GitHub access token with read access to public repos
  }
end

###########################
# Setup extra credentials #
###########################
json_credentials = ENV['EXTRA_CREDENTIALS'] || ""
unless json_credentials.to_s.strip.empty?
  json_credentials = JSON.parse(json_credentials)
  credentials.push(*json_credentials)
  # Adding custom private feed removes the public onces so we have to create it
  if package_manager == "nuget"
    credentials << {
      "type" => "nuget_feed",
      "url" => "https://api.nuget.org/v3/index.json",
    }
  end
end

source = Dependabot::Source.new(
  provider: "azure",
  hostname: azure_hostname,
  api_endpoint: "https://#{azure_hostname}/",
  repo: repo_name,
  directory: directory,
  branch: branch,
)

##############################
# Fetch the dependency files #
##############################
puts "Fetching #{package_manager} dependency files for #{repo_name}"
puts "Targeting '#{branch || 'default'}' branch under '#{directory}' directory"
puts "Using '#{update_strategy}' versioning strategy"
fetcher = Dependabot::FileFetchers.for_package_manager(package_manager).new(
  source: source,
  credentials: credentials,
)

files = fetcher.files
commit = fetcher.commit

##############################
# Parse the dependency files #
##############################
puts "Parsing dependencies information"
parser = Dependabot::FileParsers.for_package_manager(package_manager).new(
  dependency_files: files,
  source: source,
  credentials: credentials,
)

dependencies = parser.parse

pull_requests_limit = ENV["OPEN_PULL_REQUESTS_LIMIT"].to_i || 5
pull_requests_count = 0

dependencies.select(&:top_level?).each do |dep|
  #########################################
  # Get update details for the dependency #
  #########################################
  puts "Checking if #{dep.name} #{dep.version} needs updating"

  checker = Dependabot::UpdateCheckers.for_package_manager(package_manager).new(
    dependency: dep,
    dependency_files: files,
    credentials: credentials,
    requirements_update_strategy: update_strategy,
  )

  if checker.up_to_date?
    puts "No update needed for #{dep.name} #{dep.version}"
    next
  end

  requirements_to_unlock =
    if !checker.requirements_unlocked_or_can_be?
      if checker.can_update?(requirements_to_unlock: :none) then :none
      else :update_not_possible
      end
    elsif checker.can_update?(requirements_to_unlock: :own) then :own
    elsif checker.can_update?(requirements_to_unlock: :all) then :all
    else :update_not_possible
    end

  puts "Requirements to unlock #{requirements_to_unlock}"
  next if requirements_to_unlock == :update_not_possible

  updated_deps = checker.updated_dependencies(
    requirements_to_unlock: requirements_to_unlock
  )

  #####################################
  # Generate updated dependency files #
  #####################################
  puts "Updating #{dep.name} from #{dep.version} to #{checker.latest_version}"
  updater = Dependabot::FileUpdaters.for_package_manager(package_manager).new(
    dependencies: updated_deps,
    dependency_files: files,
    credentials: credentials,
  )

  updated_files = updater.updated_dependency_files

  ########################################
  # Create a pull request for the update #
  ########################################
  pr_creator = Dependabot::PullRequestCreator.new(
    source: source,
    base_commit: commit,
    dependencies: updated_deps,
    files: updated_files,
    credentials: credentials,
    label_language: true,
    author_details: {
      email: "noreply@github.com",
      name: "dependabot[bot]"
    },
  )

  print "Submitting #{dep.name} pull request for creation. "
  pull_request = pr_creator.create

  if pull_request
    content = JSON[pull_request.body]
    if pull_request&.status == 201
      puts "Done (PR ##{content["pullRequestId"]})"
    else
      puts "Failed! PR already exists or an error has occurred."
      puts "Status: #{pull_request&.status}."
      puts "Message #{content["message"]}"
    end
  else
    puts "Seems PR is already present."
  end

  # Check if we have reached maximum number of open pull requests
  pull_requests_count += 1
  if pull_requests_limit > 0 && pull_requests_count >= pull_requests_limit
    puts "Limit of open pull requests (#{pull_requests_limit}) reached."
    break
  end

  next unless pull_request

end

puts "Done"
