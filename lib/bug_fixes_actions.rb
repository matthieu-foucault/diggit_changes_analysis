class BugFixesActions < PreviousActions
	def actions_col
		"bugfixes_actions"
	end

	def extract_actions
		extract_commits_actions(src_opt[@source]["bug-fix-commits"].map { |c| repo.lookup(c) }, 0)
	end
end
