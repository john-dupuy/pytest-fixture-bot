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
# get fixture_eval config
fixture_eval = config["repositories"][repo_name]["fixture_eval"]
if !fixture_eval[:enabled]
  abort("#{repo_name} unsupported for fixture evaluation")
end


# make an empty functions to check dict ({file: <list of functions>})
funcs_to_check = Hash.new(0)

puts "Processing repo #{repo_name}"
repo = client.repository repo_name


pull_request = client.pull_request repo_name, pr_id
pr_files = client.pull_request_files repo_name, pr_id

puts pull_request.number == 8963
abort

def get_fixture_eval_comments_hashes client, repo_name, pr
    client.issue_comments(repo_name, pr).map(&:body).map {|c| c.strip.match(/^Fixture evaluation report for commit ([a-fA-F0-9]+)/)}.reject {|h| h.nil?}.map{|c| c[1]}
end

def true?(obj)
  # this takes the string "True" or "False" and converts it to a ruby boolean
  obj.downcase.to_s == "true"
end

# get the functions modified by the PR
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

      # for each fixture, find where it's used 
      fixtures_for_comment[func_name] = Hash.new(0)

      # determine whether it is a global or local fixture
      is_global = false
      if module_name.include? fixture_eval["global_path"] or module_name.include? fixture_eval["global_path"].gsub("/", ".")
        search_loc = fixture_eval["search_loc"] # global fixture
        is_global = true
      else
        search_loc = module_name.gsub(".","/").concat(".py") # local fixture
      end

      puts "#{func_name} is a fixture, finding usages of it in test cases within #{search_loc}"
      
      fixture_usages = `cd tmp/clone && grep -H -r #{func_name} #{search_loc}`.strip.split(/\n/)

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

# create the comment
fixture_evaluated = get_fixture_eval_comments_hashes client, repo_name, pull_request.number
any_fixture_changed = ! fixtures_for_comment.empty?
unless fixture_evaluated.include? pull_request.head.sha
  if any_fixture_changed
    comment_body = "Fixture evaluation report for commit #{pull_request.head.sha}\n"
    fixtures_for_comment.each do |fixture_name, file_hash|
      comment_body << "\n`#{fixture_name}` is used by the following files:\n"
      file_hash.each do |file_name, function_array|
        comment_body << "- **#{file_name}**\n"
        function_array.each do |function_name|
          comment_body << "    *#{function_name}*\n"
        end 
      end
    end
  # post the comment
  comment_body << "\nPlease, check these functions to make sure your fixture changes do not break existing usage :smiley:"
  client.add_comment repo_name, pull_request.number, comment_body
  end
end
