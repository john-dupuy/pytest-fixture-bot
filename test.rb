#!/usr/bin/env ruby
require "octokit"
require "yaml"
require "git_diff_parser"

# set some global constants
Octokit.auto_paginate = true
config = YAML.load_file("ghbot.yaml")
repo_name = "ManageIQ/integration_tests"
pr_id = 8963
client = Octokit::Client.new(config["credentials"] || {})

# make an empty functions to check dict ({file: <list of functions>})
funcs_to_check = Hash.new(0)

puts "Processing repo #{repo_name}"
repo = client.repository repo_name
pull_request = client.pull_request repo_name, pr_id
pr_files = client.pull_request_files repo_name, pr_id

def true?(obj)
  # this takes the string "True" or "False" and converts it to a ruby boolean
  obj.downcase.to_s == "true"
end

pr_files.each do |file|
  # get the module name
  module_name = file.filename.chomp(".py").gsub("/", ".")

  # store each file in the Hash
  funcs_to_check[module_name] = []

  patch = GitDiffParser::Patch.new(file.patch)
  lines = file.patch.split(/\n/)


  # within each line find the function names that have altered code in them
  lines.each do |line|
      if match = line.match(/def ([a-zA-Z_{1}][a-zA-Z0-9_]+)(?=\()/)
        funcs_to_check[module_name] << match.captures[0]
      end
  end
end

# define a Hash that will be used for he GH comment 
fixtures_for_comment = Hash.new(0)

# now for each of these figure out if it is a fixture
funcs_to_check.each do |module_name, function_array|
  function_array.each do |func_name|
    cmd_result = `cd tmp/clone && python -c "from #{module_name} import #{func_name}; print('_pytestfixturefunction' in #{func_name}.__dict__.keys())"`.strip 
    # if the cmd_result is a fixture, then find usages of it!
    if true?(cmd_result)
      puts "#{func_name} is a fixture, finding usages of it in test cases within #{repo_name}"

      # for each fixture, write a list of matches
      fixtures_for_comment[func_name] = Hash.new(0)

      fixture_usages = `cd tmp/clone && grep -r #{func_name} cfme/tests/`.strip.split(/\n/)
      # now find out of the usages, which functions we want to list
      old_file = ""
      fixture_usages.each do |line|
        if match = line.match(/def ([a-zA-Z_{1}][a-zA-Z0-9_]+)(?=\()/)
          new_file = line.split(":")[0]

          if old_file != new_file
            fixtures_for_comment[func_name][new_file] = []
          end
          fixtures_for_comment[func_name][new_file] << match.captures[0]

        old_file = new_file
        end
      end
    end
  end
end
puts fixtures_for_comment
