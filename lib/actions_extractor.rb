require 'nokogiri'
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
		src_dir = "#{out.tmp}/#{TMP_DIR_SRC}/"
		dest_dir = "#{out.tmp}/#{TMP_DIR_DEST}/"

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
			repo.checkout_tree(commit_tree, { strategy: [:force], paths: dest_path, target_directory: dest_dir, baseline: nil })
			src_tree = parent_tree
		end

		FileUtils.touch(dest_dir + dest_path) if patch.delta.added? || patch.delta.deleted?
		FileUtils.rm(src_dir + src_path) if File.exist? src_dir + src_path
		repo.checkout_tree(src_tree, { strategy: [:force], paths: src_path, target_directory: src_dir, baseline: nil })

		[src_dir + src_path, dest_dir + dest_path]
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