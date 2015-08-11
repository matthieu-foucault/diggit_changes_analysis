# encoding: utf-8

require 'diggit/developers_activity/analyses/activity_analysis'
require 'diggit/developers_activity'
require_relative 'actions_extractor'

class PreviousActions < Diggit::DevelopersActivity::Analyses::ActivityAnalysis
	include ActionsExtractor
	require_addons 'out'

	TIME_PERIOD_SIZE = 3600 * 24 * 30

	def actions_col
		"actions"
	end

	def run
		super
		@release_files = Modules.files_from_cloc_analysis
		@num_commits = 0
		@num_commits_without_action = 0

		extract_actions

		puts "#{@num_commits} commits, #{@num_commits_without_action} without action"
	end

	def extract_actions
		s_0 = repo.lookup(src_opt[@source]["cloc-commit-id"])
		t_first = repo.lookup(src_opt[@source]["R_first"]).author[:time]
		t_0 = s_0.author[:time]
		t_previous_month = t_0 - TIME_PERIOD_SIZE
		month_num = 1

		walker = Rugged::Walker.new(repo)
		walker.sorting(Rugged::SORT_DATE)
		walker.push(s_0)

		commits = []
		walker.each do |commit|
			t = commit.author[:time]
			Renames.extract_commit_renames(commit)
			commits << commit if commit.parents.size == 1
			if t < t_previous_month || t < t_first
				puts "[#{Time.new}] Month #{month_num}, #{commits.size} commits"
				extract_commits_actions(commits, month_num)
				month_num += 1
				t_previous_month -= TIME_PERIOD_SIZE
				commits = []
			end
			break if t < t_first
		end
	end

	def extract_commits_actions(commits, month_num)
		actions_count = Hash.new(0)
		commits.each do |commit|
			commit_has_actions = false
			author = Authors.get_author(commit)
			commit.parents.each do |parent|
				diff = parent.diff(commit, Diggit::DevelopersActivity::DIFF_OPTIONS)
				diff.find_similar!(Diggit::DevelopersActivity::DIFF_RENAME_OPTIONS)
				diff.each do |patch|
					maudule = Modules.get_patch_module(patch)
					file = Renames.apply(patch.delta.old_file[:path])
					next if maudule.nil?
					actions = get_actions(patch, commit, parent)
					commit_has_actions = true unless actions.empty?
					actions.each do |action|
						key = { developer: author, "module" => maudule, kind: action.kind, element: action.element,
							commit: commit.oid.to_s, file: file, date: commit.author[:time] }
						actions_count[key] = actions_count[key] + 1
					end
				end
			end
			@num_commits += 1
			@num_commits_without_action += 1 unless commit_has_actions
		end
		entries = []
		actions_count.each_pair do |key, count|
			entries << key.merge({ count: count, month_num: month_num, project: @source.url })
		end
		db.insert(actions_col, entries)
	end

	def clean
		db.client[actions_col].find({ project: @source.url }).delete_many
	end
end
