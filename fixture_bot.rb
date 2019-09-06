#!/usr/bin/env ruby
require "octokit"
require "ostruct"
require "yaml"
require "git_diff_parser"

Octokit.auto_paginate = true
config = YAML.load_file("conf/fixture_bot.yaml")
client = Octokit::Client.new(config["credentials"] || {})

bot_user_name = config['credentials'][:login]


def bot_comments client, repo_name, pr
    client.issue_comments(repo_name, pr).reject {|c| c[:body].strip.match(/^I detected some fixture changes in commit ([a-fA-F0-9]+)/).nil? }
end


def get_fixture_eval_comments_hashes client, repo_name, pr
    client.issue_comments(repo_name, pr).map(&:body).map {|c| c.strip.match(/^I detected some fixture changes in commit ([a-fA-F0-9]+)/)}.reject {|h| h.nil?}.map{|c| c[1]}
end


def remove_old_fixture_eval_comments client, repo_name, pr
    comments = bot_comments client, repo_name, pr
    comments.each do |comment|
        client.delete_comment repo_name, comment.id
    end
end


def build_gh_comment fixtures_for_comment, pull_request, max_comment_length
    comment_body = "I detected some fixture changes in commit #{pull_request.head.sha}\n"
    # first determine whether the comment will be greater than 30 lines, if so, we want to hide the comment
    nl = fixtures_for_comment.size
    fixtures_for_comment.each do |fixture_name, file_hash|
        nl += file_hash.size
        file_hash.each do |file_name, function_array|
            next unless file_name.include? ".py"
            nl += function_array.size
        end
    end
    comment_body << "\n<details>\n<summary>\n<b>Show fixtures</b>\n</summary>\n\n" if nl > max_comment_length
    
    fixtures_for_comment.each do |fixture_name, file_hash|
        local_or_global = "*local*"
        if file_hash["is_global"]
          local_or_global = "*global*"
        end
        # If fixture was found to be changed, but no usages were found, just say that
        file_hash.delete("is_global")
        if file_hash.empty?
          comment_body << "\n The #{local_or_global} fixture **`#{fixture_name}`** was changed, but I didn't find where it's used."
          next
        end
        comment_body << "\nThe #{local_or_global} fixture **`#{fixture_name}`** is used in the following files:\n"
        file_hash.each do |file_name, function_array|
            next unless file_name.include? ".py"
            comment_body << "- **#{file_name}**\n"
            function_array.each do |function_name|
                comment_body << "    - *#{function_name}*\n"
            end 
        end
    end
    comment_body << "\n</details>\n" if nl > max_comment_length 
    comment_body << "\nPlease, consider creating a PRT run to make sure your fixture changes do not break existing usage :smiley:"
end


def max (a,b)
    a>b ? a : b
end


# main loop for script 
(config["repositories"] || {}).each do |repo_name, repo_data|
    puts "Processing repository #{repo_name} ->"
    repo = client.repository repo_name
    labels = client.labels(repo_name).map { |lbl| lbl[:name] }
     
    # Extract data for fixture evaluation
    fixture_eval = repo_data["fixture_eval"]

    unless fixture_eval.nil?
        fixture_eval_enabled = fixture_eval[:enabled]
        fixture_search = fixture_eval["search_loc"] || ""
        fixture_global = fixture_eval["global_loc"] || ""
        fixture_clone = fixture_eval["clone_loc"] || ""
        testing = fixture_eval[:testing] || false
        test_pr_no = fixture_eval["test_pr"] || 0
        max_comment_length = fixture_eval["max_comment_length"] || 30
    end
    
    # skip the repo if fixture_eval is not enabled
    next unless fixture_eval_enabled
    
    # loop over pull requests and check the things
    client.pull_requests(repo_name, :state => "open").each do |pull_request|

        if testing
            next unless pull_request.number == test_pr_no
        end

        # some variables
        # We have to retrieve full PR object here
        pull_request = client.pull_request repo_name, pull_request.number
        pr_files = client.pull_request_files repo_name, pull_request.number
        fixtures_for_comment = Hash.new(0)
        puts " Processing PR\##{pull_request.number}@#{repo_name} ->"
        
        # Read labels, names only
        pr_labels = client.labels_for_issue(repo_name, pull_request.number).map { |lbl| lbl[:name] }
 
        # Fixture evaluation
        fixture_evaluated = get_fixture_eval_comments_hashes client, repo_name, pull_request.number
        if fixture_eval_enabled && (! fixture_evaluated.include? pull_request.head.sha) 
            # first clone the repo
            clone_url = pull_request.head.repo.git_url
            branch = pull_request.head.ref
            `mkdir -p #{fixture_clone}; rm -rf #{fixture_clone}/clone`
            `git clone -b #{branch} #{clone_url} #{fixture_clone}/clone`

            # make a Hash to list functions that have been modified
            fixtures_for_comment = Hash.new(0)
            # get the functions modified by the PR
            pr_files.each do |file|
                fixtures_in_file = []
                # get the module name
                module_name = file.filename.chomp(".py").gsub("/", ".")
                # parse the patch
                patch = GitDiffParser::Patch.new(file.patch)
                
                # TODO: figure out a way to not recheck line numbers that are close to one another
                changed_lines = patch.changed_line_numbers
                
                changed_lines.each_with_index do |line_no, i|
                
                    lines_to_search = max(line_no - 100, 1)
                    # use sed command to find the parent function of the line changed
                    cmd_result = `sed '#{lines_to_search},#{line_no}!d' #{fixture_clone}/clone/#{file.filename}`.lines.map(&:chomp)
                    # determine if the line is indented (skip if it is not)
                    next unless cmd_result[-1][0] == " " 
                    # skip empty lines
                    next if cmd_result[-1].strip().empty?
                    
                    # now loop over this array backwards to find fixtures and functions
                    cmd_result.reverse.each_with_index do |line, index|
                        next if cmd_result[index+1].nil?

                        # find the parent function
                        if match = line.match(/    def ([a-zA-Z_{1}][a-zA-Z0-9_]+)(?=\()/)
                            # determine if the parent function is a fixture by checking the line above its definition
                            if fixture_or_not = cmd_result.reverse[index+1].match(/@pytest.fixture/)
                                fixture_name = match.captures[0]
                                fixtures_in_file << fixture_name 
                                break
                            # TODO: find a way to deal with functions that exist in fixture wrappers 
                            end
                            break
                        elsif match = line.match(/def ([a-zA-Z_{1}][a-zA-Z0-9_]+)(?=\()/)
                            if fixture_or_not = cmd_result.reverse[index+1].match(/@pytest.fixture/)
                                fixture_name = match.captures[0]
                                fixtures_in_file << fixture_name 
                                break
                            end
                            break
                        end
                    end
                end

                unless fixtures_in_file.empty?
                    # get rid of duplicate entries in the array
                    fixtures_in_file = fixtures_in_file.uniq
                    # we have a list of modified fixtures, now we're ready to build our comment
                    fixtures_in_file.each do |func_name|
                        fixtures_for_comment[func_name] = Hash.new(0)
                        
                        is_global = false
                        
                        # determine whether or not it's a global fixture
                        if fixture_global.kind_of?(Array)
                            fixture_global.each do |global_loc|
                                if module_name.include? global_loc or module_name.include? global_loc.gsub("/",".")
                                    is_global = true
                                    break
                                end
                            end
                        else
                            if module_name.include? fixture_global or module_name.include? fixture_global.gsub("/",".")
                                is_global = true
                            end
                        end

                        if is_global
                            search_loc = fixture_search
                        else
                            search_loc = module_name.gsub(".","/").concat(".py") # local fixture
                        end
                            
                        # store global property
                        fixtures_for_comment[func_name]["is_global"] = is_global

                        puts "#{func_name} is a fixture, finding usages of it within #{search_loc}"

                        fixture_usages = `cd #{fixture_clone}/clone && grep -H -r '\\<#{func_name}\\>' #{search_loc}`.strip.split(/\n/)

                        # now find out of the usages, which functions we want to list
                        old_file = ""
                        fixture_usages.each do |line|
                            # TODO: handle fixtures that are not in the line of the function definition
                            new_file = line.split(":")[0]
                            if match = line.match(/def ([a-zA-Z_{1}][a-zA-Z0-9_]+)(?=\()/)
                                # also make sure that the there isn't a local fixture defined in that file
                                skip = false
                                if is_global
                                    cmd = `cd #{fixture_clone}/clone && grep -H 'def #{func_name}(' #{new_file}`.strip.split(/\n/)
                                    skip = !cmd.empty?
                                end

                                if old_file != new_file
                                    unless skip
                                        fixtures_for_comment[func_name][new_file] = []
                                    end
                                end
                                # make sure we don't list the fixture under the message
                                unless func_name == match.captures[0]
                                    unless skip
                                        fixtures_for_comment[func_name][new_file] << match.captures[0]
                                    end
                                end
                            else
                                # if a fixture is found in a file, but it's not clear what function it's in, also report
                                if old_file != new_file 
                                    # make sure that there is a comma after the fixture_name
                                    cmd = `cd #{fixture_clone}/clone && grep -H '#{func_name},' #{new_file}`.strip.split(/\n/)
                                    if cmd.empty?
                                      # also search for a paratheses after the fixture name
                                      cmd = `cd #{fixture_clone}/clone && grep -H '#{func_name})' #{new_file}`.strip.split(/\n/)
                                    end
                                    if !cmd.empty? 
                                      fixtures_for_comment[func_name][new_file] = []
                                    end
                                end
                            end
                            old_file = new_file
                        end
                    end
                end
            end

            # TODO: add a label for whether or not the fixtures have been evaluated
            unless fixtures_for_comment.empty?
                puts "Adding fixture evaluation comment for #{pull_request.head.sha}"
                remove_old_fixture_eval_comments client, repo_name, pull_request.number
                comment_body = build_gh_comment fixtures_for_comment, pull_request, max_comment_length
                client.add_comment repo_name, pull_request.number, comment_body
            end
        end
    end
end
