# encoding: utf-8

require 'nokogiri'
require 'diggit_process_metrics'
require 'pry'
require 'fileutils'
module ActionsExtractor



	class Action
		attr_accessor :kind, :element

		def initialize(kind, element)
			@kind = kind
			@element = element
		end
	end

	GUMTREE_JAR = "~/.m2/repository/fr/labri/gumtree/client/1.0-SNAPSHOT/client-1.0-SNAPSHOT.jar"
	GUMTREE_EXEC = "java -cp #{GUMTREE_JAR} fr.labri.gumtree.client.DiffClient -o actions"
	EMPTY_FILE_NAME = "devnull"
	TMP_DIR_SRC = "src"
	TMP_DIR_DEST = "dest"

	def get_actions(patch, commit, parent)
		#require "pry"; binding.pry
		files = checkout_patch(patch, commit.tree, parent.tree)
		#puts "#{files[0]} --- #{files[1]} --- #{commit.oid.to_s}"
		#binding.pry if commit.oid.to_s == "d97b0834c8dc14d9d7ecd6634455f829d3644005"
		gumtree(files[0], files[1], patch.delta)
	end

	def checkout_patch(patch, commit_tree, parent_tree)

		src_dir = "#{@addons[:output].tmp}/#{TMP_DIR_SRC}/"
		dest_dir = "#{@addons[:output].tmp}/#{TMP_DIR_DEST}/"

		case
		when patch.delta.added?
			# FIXME: ugly working aroud gumtree and empty files : in case of a creation, src and dest are reversed
			src_path = patch.delta.new_file[:path]
			dest_path = EMPTY_FILE_NAME + File.extname(src_path)
			src_tree = commit_tree

		when patch.delta.deleted?
			src_path = patch.delta.old_file[:path]
			dest_path = EMPTY_FILE_NAME + File.extname(src_path)
			src_tree = parent_tree

		else
			src_path = patch.delta.old_file[:path]
			dest_path = patch.delta.new_file[:path]
			FileUtils.rm(dest_dir + dest_path) if File.exist? dest_dir + dest_path
			@repo.checkout_tree(commit_tree, {:strategy=>[:force], :paths=>dest_path, :target_directory=>dest_dir, baseline:nil})
			src_tree = parent_tree
		end

		FileUtils.touch(dest_dir + dest_path) if patch.delta.added? || patch.delta.deleted?
		FileUtils.rm(src_dir + src_path) if File.exist? src_dir + src_path
		@repo.checkout_tree(src_tree, {:strategy=>[:force], :paths=>src_path, :target_directory=>src_dir, baseline:nil})

		[src_dir + src_path,dest_dir + dest_path]
	end

	def gumtree(src_path, dest_path, delta)
		gumtree_out = `#{GUMTREE_EXEC} #{src_path} #{dest_path}`
		xml = Nokogiri::XML(gumtree_out)
		actions = []
		xml.xpath("//actions/action").each do |action_node|
			kind = action_node.xpath("@type").text.downcase.to_sym
			element = action_node.xpath("tree/@typeLabel").text

			next if element.empty?

			if delta.added?
				# TRICKY: actions kinds are reversed here
				next if kind == :insert
				kind = :insert if kind == :delete
			elsif delta.deleted?
				next if kind == :insert
			end

			actions << Action.new(kind, element)
		end
		actions
	end
end

class ChangesAnalysis < ProcessMetricsAnalysis
	include ActionsExtractor

	TIME_PERIOD_SIZE = 3600 * 24 * 30
	ACTIONS_COL = "actions"

	def run
		@release_files = get_files_from_db
		r_0 = @repo.lookup(src_opt["cloc-commit-id"])
		t_first = @repo.lookup(src_opt["R_first"]).author[:time]

		t_0 = r_0.author[:time]


		walker = Rugged::Walker.new(@repo)
		walker.sorting(Rugged::SORT_DATE)
		walker.push(r_0)

		@renames = {}
		t_previous_month = t_0 - TIME_PERIOD_SIZE
		month_num = 1
		@num_commits = 0
		@num_commits_without_action = 0

		commits = []
		walker.each do |commit|
			t = commit.author[:time]
			extract_commit_renames(commit, false)
			commits << commit if commit.parents.size == 1
			if t < t_previous_month || t < t_first
				puts "[#{Time.new}] Month #{month_num}, #{commits.size} commits"
				m = extract_changes_metrics(commits, month_num)
				month_num = month_num + 1
				t_previous_month = t_previous_month - TIME_PERIOD_SIZE
				commits = []
			end
			break if t < t_first
		end
		puts "#{@num_commits} commits, #{@num_commits_without_action} without action"
	end

	def extract_changes_metrics(commits, month_num)
		actions_count = Hash.new(0)
		commits.each do |commit|
			commit_has_actions = false
			author = get_author(commit)
			commit.parents.each do |parent|
				diff = parent.diff(commit, DIFF_OPTIONS)
				diff.find_similar!(DIFF_RENAME_OPTIONS)
				diff.each do |patch|
					maudule = get_patch_module(patch)
					file = apply_renames(patch.delta.old_file[:path])
					next if maudule.nil?
					actions = get_actions(patch, commit, parent)
					commit_has_actions = true unless actions.empty?
					
					actions.each do |action|
						key = {author:author, maudule:maudule, kind:action.kind, element:action.element, commit:commit.oid.to_s, file:file, date:commit.author[:time]}
						actions_count[key] = actions_count[key] + 1
					end
				end	
			end	
			@num_commits = @num_commits + 1
			@num_commits_without_action = @num_commits_without_action + 1 unless commit_has_actions
		end
		
		entries = []
		actions_count.each_pair do |key, count|
			entries << key.merge({count:count, month_num:month_num, source:@source})
		end
		@addons[:db].db[ACTIONS_COL].insert(entries) unless entries.empty?	
	end

	def clean
		@addons[:db].db[ACTIONS_COL].remove({source:@source})
	end
end