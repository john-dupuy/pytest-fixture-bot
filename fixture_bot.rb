#!/usr/bin/env ruby
require "octokit"
require "ostruct"
require "yaml"
require "git_diff_parser"

Octokit.auto_paginate = true
config = YAML.load_file("fixture_bot.yaml")
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
    comment_body << "\nPlease, consider creating a PRT run against these tests make sure your fixture changes do not break existing usage :smiley:"
end

def true?(obj)
  # this takes the string "True" or "False" and converts it to a ruby boolean
  obj.downcase.to_s == "true"
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
        max_comment_length = fixture_eval["max_comment_length"] || 30
    end

    
    # loop over pull requests and check the things
    client.pull_requests(repo_name, :state => "open").each do |pull_request|

        # REMOVE THIS before merge (just for testing)
        next unless pull_request.number == 8963

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
            # make a Hash to list functions that have been modified
            funcs_to_check = Hash.new(0)
            # get the functions modified by the PR
            pr_files.each do |file|
                # get the module name
                module_name = file.filename.chomp(".py").gsub("/", ".")

                # store each file in the Hash
                funcs_to_check[module_name] = []
                classes_modified = []

                patch = GitDiffParser::Patch.new(file.patch)
                lines = file.patch.split(/\n/)


                # within each line find the function names that have altered code in them
                lines.each do |line|
                    # also find any classes that were modified
                    if match = line.match(/class ([a-zA-Z_{1}][a-zA-Z0-9_]+)(?=\()/)
                        classes_modified << match.captures[0]
                    end
                    # first check if the fixture is part of a class (it will be tabbed over)
                    if match = line.match(/    def ([a-zA-Z_{1}][a-zA-Z0-9_]+)(?=\()/)
                        # since the class will always be found before the function, should be safe to use last index for class_name
                        found_function = OpenStruct.new(:name => match.captures[0], :in_class? => true, :class_name => classes_modified[-1])
                        funcs_to_check[module_name] << found_function 
                    elsif match = line.match(/def ([a-zA-Z_{1}][a-zA-Z0-9_]+)(?=\()/)
                        found_function = OpenStruct.new(:name => match.captures[0], :in_class? => false)
                        funcs_to_check[module_name] << found_function 
                    end

                end
            end
             
            clone_url = pull_request.head.repo.git_url
            branch = pull_request.head.ref
            unless funcs_to_check.empty?
                # clone the repo
                `mkdir -p #{fixture_clone}; rm -rf #{fixture_clone}/clone`
                `git clone -b #{branch} #{clone_url} #{fixture_clone}/clone`
                # loop over each function and check if it is a fixture
                funcs_to_check.each do |module_name, function_array|
                    function_array.each do |func_struct|
                        func_name = func_struct.name

                        if func_struct.in_class?
                            class_name = func_struct.class_name
                            cmd_result = `cd #{fixture_clone}/clone && python -c "from #{module_name} import #{class_name}; print('_pytestfixturefunction' in #{class_name}.#{func_name}.__dict__.keys())"`.strip
                        else
                            cmd_result = `cd #{fixture_clone}/clone && python -c "from #{module_name} import #{func_name}; print('_pytestfixturefunction' in #{func_name}.__dict__.keys())"`.strip
                        end
                        # if true, this is a fixture!
                        if true?(cmd_result) 
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

                            fixture_usages = `cd #{fixture_clone}/clone && grep -H -r #{func_name} #{search_loc}`.strip.split(/\n/)

                            # now find out of the usages, which functions we want to list
                            old_file = ""
                            fixture_usages.each do |line|
                                if match = line.match(/def ([a-zA-Z_{1}][a-zA-Z0-9_]+)(?=\()/)
                                    new_file = line.split(":")[0]

                                    if old_file != new_file
                                        fixtures_for_comment[func_name][new_file] = []
                                    end
                                    # make sure we don't list the fixture under the message
                                    unless func_name == match.captures[0] 
                                        fixtures_for_comment[func_name][new_file] << match.captures[0]
                                    end

                                    old_file = new_file
                                end
                            end
                        end
                    end
                end
            end
            # build & post the comment
            unless fixtures_for_comment.empty? && (fixture_evaluated.include? pull_request.head.sha)
                puts "Adding fixture evaluation comment for #{pull_request.head.sha}"
                remove_old_fixture_eval_comments client, repo_name, pull_request.number
                comment_body = build_gh_comment fixtures_for_comment, pull_request, max_comment_length
                client.add_comment repo_name, pull_request.number, comment_body
            end    
        end
    end
end
