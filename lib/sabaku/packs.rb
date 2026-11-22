# frozen_string_literal: true

require "psych"

require_relative "errors"

module Sabaku
  # The Packwerk package graph, read from package.yml files. Only the CLI uses it, to turn
  # `--tests=pack` into test globs: a test in a pack that depends on the target's pack can
  # kill its mutants, and the engine below the CLI only ever sees the globs.
  module Packs
    ROOT = "."
    # Packwerk's default exclude list; a gem under vendor/ can ship its own package.yml.
    EXCLUDED = %r{\A(?:bin|node_modules|script|tmp|vendor)/}

    # name  the directory holding package.yml, relative to the project root ("." for the root
    #       package), which is also the name Packwerk gives the pack
    Pack = Data.define(:name, :dependencies) do
      def test_glob = name == ROOT ? "test/**/*_test.rb" : "#{name}/test/**/*_test.rb"

      def owns?(path) = name == ROOT || path.start_with?("#{name}/")
    end

    Graph = Data.define(:packs) do
      # The deepest pack whose directory holds +path+.
      def pack_of(path)
        packs.select { |pack| pack.owns?(path) }.max_by { |pack| pack.name == ROOT ? -1 : pack.name.length }
      end

      # Every pack that depends on one of +names+, directly or through another pack.
      def dependents(names)
        found = {}
        frontier = names.dup
        until frontier.empty?
          name = frontier.shift
          packs.each do |pack|
            next if found[pack.name] || names.include?(pack.name) || !pack.dependencies.include?(name)

            found[pack.name] = pack
            frontier << pack.name
          end
        end
        found.values
      end

      # The owning packs of +paths+, their dependents, and the root package, which in
      # Packwerk depends on every pack.
      def test_globs_for(paths)
        owners = paths.filter_map { |path| pack_of(path) }.uniq
        root = packs.find { |pack| pack.name == ROOT }
        (owners + dependents(owners.map(&:name)) + [root]).compact.map(&:test_glob).uniq.sort
      end
    end

    def self.load(root_dir)
      files = Dir.glob("**/package.yml", base: root_dir).reject { |file| file.match?(EXCLUDED) }
      raise Sabaku::Error, "--tests=pack needs a package.yml under #{root_dir}" if files.empty?

      packs = files.sort.map do |file|
        data = Psych.safe_load(File.read(File.join(root_dir, file))) || {}
        Pack.new(name: File.dirname(file), dependencies: Array(data["dependencies"]).map(&:to_s).freeze)
      end
      Graph.new(packs: packs.freeze)
    end
  end
end
