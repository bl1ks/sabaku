# frozen_string_literal: true

require "optparse"
require "json"

module Sabaku
  # Argument parsing and the three verbs. The CLI is the only place that touches a project's
  # filesystem layout: everything below takes paths and a frozen Config.
  class CLI
    EXIT_OK = 0
    EXIT_BELOW_SCORE = 1
    EXIT_ERROR = 2

    def self.start(argv, out: $stdout, err: $stderr)
      new(argv, out: out, err: err).run
    end

    def initialize(argv, out: $stdout, err: $stderr)
      @argv = argv.dup
      @out = out
      @err = err
    end

    def run
      command = @argv.shift
      case command
      when nil, "-h", "--help", "help"
        @out.puts(help)
        EXIT_OK
      when "-v", "--version", "version"
        @out.puts("sabaku #{VERSION}")
        EXIT_OK
      when "run" then run_command
      when "list" then list_command
      when "doctor" then doctor_command
      else
        @err.puts("unknown command #{command.inspect}, try `sabaku help`")
        EXIT_ERROR
      end
    rescue Sabaku::Error, OptionParser::ParseError => e
      @err.puts("mutation: #{e.message}")
      EXIT_ERROR
    rescue LoadError => e
      # LoadError is a ScriptError, not a StandardError, so it would otherwise escape the
      # CLI and exit 1 with a raw backtrace, which reads like a test failure.
      @err.puts("mutation: #{e.message}")
      @err.puts("mutation: a gem the suite needs is not installed; add it to your bundle")
      EXIT_ERROR
    rescue StandardError => e
      @err.puts("mutation: #{e.class}: #{e.message}")
      @err.puts(e.backtrace.first(8).join("\n")) if ENV["SABAKU_DEBUG"]
      EXIT_ERROR
    end

    private

    def run_command
      options = parse
      return EXIT_OK unless options

      cfg = build_config(options)
      Boot.env(cfg)
      sources = load_sources(cfg)
      analyzer = Analyzer.new(sources, cfg)
      mutants = analyzer.mutants
      mutants = mutants.first(options[:limit]) if options[:limit]
      if mutants.empty?
        @err.puts("mutation: no mutants to run (check the paths and --diff)")
        return EXIT_OK
      end

      adapter = start_adapter(cfg)
      coverage = collect_coverage(cfg, adapter, sources, mutants)
      if coverage.nil?
        # Selection failed. Running every test for every mutant is slow but correct;
        # an empty map would instead mark every mutant uncovered and score the run 0.
        @err.puts("mutation: continuing without coverage-based selection")
        cfg = cfg.with(coverage: false)
        coverage_map = CoverageMap.empty
        weak = nil
      else
        coverage_map, weak = coverage
      end
      runner = Runner.new(cfg, analyzer: analyzer, adapter: adapter,
                               coverage_map: coverage_map, weak: weak)
      results = runner.call(mutants)

      matrix = kill_matrix(cfg, results, runner, coverage_map, adapter)
      report = Report.new(results, cfg, kill_matrix: matrix, coverage_files: coverage_map.files)
      emit(report, cfg)
      errored = report.counts[:error]
      if errored.positive?
        @err.puts("mutation: #{errored} of #{report.results.size} mutants produced no " \
                  "result, so the score excludes them and does not measure the suite")
        first = report.results.find { |result| result.status == :error }
        @err.puts("mutation: first error at #{first.mutant.path}:#{first.mutant.line} " \
                  "#{first.message}") if first
        return EXIT_ERROR
      end

      threshold = options[:min_score]
      return EXIT_OK if threshold.nil?

      report.score_pct < threshold ? EXIT_BELOW_SCORE : EXIT_OK
    ensure
      finish_campaign(cfg) if cfg
    end

    # The coverage pass ran every test, so its ids name the tests no mutant selected. The
    # matrix is advice, so it never changes the exit code.
    def kill_matrix(cfg, results, runner, coverage_map, adapter)
      return nil unless cfg.kill_matrix

      universe = coverage_map.test_ids | (adapter.preloaded? ? adapter.test_ids : [])
      KillMatrix.from(results, universe: universe, selected: runner.selections, scope: cfg.kill_matrix_scope,
                               causes: runner.incomplete_causes, focus: runner.focus_ids)
    end

    # after_campaign runs once, after the last child, before the process exits.
    # A cleanup hook that raises is reported without changing the campaign's
    # verdict: the campaign already happened, and bin/sabaku's exit! is what
    # makes this hook the only place a setup file can clean up.
    def finish_campaign(cfg)
      Boot.fire(cfg, :after_campaign)
    rescue BootError => e
      @err.puts("mutation: #{e.message}")
    end

    def list_command
      options = parse
      return EXIT_OK unless options

      cfg = build_config(options)
      mutants = Analyzer.new(load_sources(cfg), cfg).mutants
      mutants = mutants.first(options[:limit]) if options[:limit]
      mutants.group_by(&:path).each do |path, list|
        @out.puts("#{path}  (#{list.size})")
        list.each { |m| @out.puts(format("  %5d  %-16s %s", m.line, m.operator, m.description)) }
      end
      @out.puts("\n#{mutants.size} mutants")
      EXIT_OK
    end

    def doctor_command
      @out.puts("sabaku #{VERSION}")
      @out.puts("  ruby       #{RUBY_VERSION}")
      @out.puts("  prism      #{defined?(Prism::VERSION) ? Prism::VERSION : "missing"}")
      @out.puts("  minitest   #{framework_version("minitest", "Minitest::VERSION")}")
      @out.puts("  data       #{defined?(Data) ? "ok" : "missing"}")
      @out.puts("  coverage   #{require_coverage}")
      @out.puts("  cpus       #{cpu_count}")
      @out.puts("  operators  #{Operator::Registry.ids.join(", ")}")
      EXIT_OK
    end

    # Doctor has to answer "will the suite work here", which means trying the require
    # rather than reporting whether somebody else already loaded it.
    def framework_version(gem_name, constant)
      require gem_name
      value = constant.split("::").reduce(Object) { |scope, name| scope.const_get(name) }
      value.to_s
    rescue LoadError
      "missing (#{gem_name} is not installed)"
    end

    def require_coverage
      require "coverage"
      "ok"
    rescue LoadError
      "missing"
    end

    def parse
      options = {}
      parser = OptionParser.new do |o|
        o.banner = "usage: mutation <run|list|doctor> [paths] [options]"
        o.on("--jobs=N", Integer, "mutants in flight at once") { |v| options[:jobs] = v }
        o.on("--timeout=SEC", Float, "per-mutant deadline") { |v| options[:timeout] = v }
        o.on("--operators=LIST", "comma separated operator ids") do |v|
          options[:operators] = v.split(",").map(&:strip).reject(&:empty?).map(&:to_sym)
        end
        o.on("--per-line=N|all", "mutants kept per line (default 1, all = mutant depth)") do |v|
          options[:per_line] = v
        end
        o.on("--diff=PATH", "JSON {path => [lines]} to restrict mutation") do |v|
          raw = JSON.parse(File.read(v))
          options[:diff_ranges] = raw.transform_values do |lines|
            lines.map { |l| Array(l).first..Array(l).last }
          end
        end
        o.on("--since=REV", "only mutate lines that changed since REV") { |v| options[:since] = v }
        o.on("--fail-fast", "stop at the first surviving mutant") { options[:fail_fast] = true }
        o.on("--[no-]baseline", "refuse to score a suite that is already red") { |v| options[:baseline] = v }
        o.on("--env=KEY=VALUE", "ENV entry set before the suite loads (repeatable)") do |v|
          key, value = v.split("=", 2)
          raise OptionParser::InvalidArgument, "--env needs KEY=VALUE" if value.nil?

          (options[:env] ||= {})[key] = value
        end
        o.on("--require=PATH", "require after coverage starts, before the tests (repeatable)") do |v|
          (options[:requires] ||= []) << v
        end
        o.on("--setup=PATH", "Ruby file with boot hooks (env, require_path, after_boot, ...)") do |v|
          options[:setup_path] = v
        end
        o.on("--[no-]coverage", "select tests by line coverage") { |v| options[:coverage] = v }
        o.on("--[no-]weak", "skip the dry-run probes that decide uninfected survivors") { |v| options[:weak] = v }
        o.on("--[no-]kill-matrix", "run every selected test against each killed mutant and report redundant tests") do |v|
          options[:kill_matrix] = v
        end
        o.on("--kill-matrix-scope=SCOPE", %w[class suite], "class (default) or suite: where one test can make another redundant") do |v|
          options[:kill_matrix_scope] = v.to_sym
        end
        o.on("--kill-matrix-focus=GLOB", "sweep and judge only the tests in these files (repeatable)") do |v|
          (options[:kill_matrix_focus] ||= []) << v
        end
        o.on("--sweep-timeout=SEC", Float, "deadline for one kill-matrix sweep (default: --timeout)") do |v|
          options[:sweep_timeout] = v
        end
        o.on("--isolation=MODE", "fork or process") { |v| options[:isolation] = v.to_sym }
        o.on("--report=FORMAT", "terminal, json, quiet") { |v| options[:report] = v.to_sym }
        o.on("--output=PATH", "write the JSON report here") { |v| options[:output] = v }
        o.on("--min-score=PCT", Float, "exit 1 when the reported score is below this") do |v|
          options[:min_score] = v
        end
        o.on("--exclude=GLOB", "skip files") { |v| (options[:exclude] ||= []) << v }
        o.on("--tests=GLOB", "test files to load (repeatable, default test/**/*_test.rb)") do |v|
          (options[:tests] ||= []) << v
        end
        o.on("--limit=N", Integer, "cap the number of mutants") { |v| options[:limit] = v }
        o.on("-h", "--help", "this") do
          @out.puts(o.to_s)
          throw(:help, :help)
        end
      end
      caught = catch(:help) do
        parser.parse!(@argv)
        :none
      end
      return nil if caught == :help

      options[:paths] = @argv.dup unless @argv.empty?
      options
    end

    def build_config(options)
      overrides = options.dup
      if (path = overrides.delete(:setup_path))
        overrides[:setup] = Sabaku.setup(path)
        overrides[:setup_path] = path
      end
      if (revision = overrides.delete(:since))
        changed = Diff.git_ranges(revision)
        overrides[:diff_ranges] = Diff.intersect(overrides[:diff_ranges], changed)
      end
      overrides[:test_globs] = overrides.delete(:tests) || [ENV.fetch("SABAKU_TEST_GLOB", "")].reject(&:empty?)
      keys = %i[paths exclude operators jobs timeout per_line diff_ranges
                coverage isolation report output env requires setup setup_path fail_fast baseline weak
                kill_matrix kill_matrix_scope kill_matrix_focus sweep_timeout test_globs]
      Config.default(**overrides.slice(*keys))
    end

    def load_sources(cfg)
      patterns = cfg.paths.empty? ? ["lib/**/*.rb"] : cfg.paths
      files = patterns.flat_map do |pattern|
        File.directory?(pattern) ? Dir.glob(File.join(pattern, "**/*.rb")) : Dir.glob(pattern)
      end
      files = files.uniq.reject { |f| File.directory?(f) }.reject { |f| excluded?(f, cfg.exclude) }
      raise Sabaku::Error, "no Ruby files matched #{patterns.inspect}" if files.empty?

      files.sort.map { |file| Source.new(relative(file), File.read(file)) }
    end

    def excluded?(file, globs)
      globs.any? { |glob| File.fnmatch?(glob, relative(file), File::FNM_PATHNAME | File::FNM_EXTGLOB) }
    end

    def relative(file)
      file.sub(%r{\A#{Regexp.escape(Dir.pwd)}/}, "")
    end

    def start_adapter(cfg)
      Adapters::MinitestAdapter.new(test_globs: cfg.test_globs)
    rescue LoadError => e
      raise Sabaku::Error,
            "the minitest adapter cannot be loaded (#{e.message}). " \
            "Add minitest to your bundle."
    end

    # -> [CoverageMap, Weak::Report | nil], or nil when selection is unavailable and the
    # caller turns it into --no-coverage.
    def collect_coverage(cfg, adapter, sources, mutants = nil)
      return [CoverageMap.empty, nil] unless cfg.coverage
      return [CoverageMap.empty, nil] unless defined?(Adapters::CoverageSampler)

      sampler = Adapters::CoverageSampler.new(cfg, adapter, sources, mutants: mutants)
      [sampler.call, sampler.weak_report]
    rescue BaselineError, BootError, CoverageError
      # The project has to fix its suite, its setup, or the Coverage it started.
      # Falling back to running every test would score failing tests as kills,
      # and a boot hook that did not run would silently change the measurement.
      raise
    rescue StandardError, LoadError => e
      @err.puts("mutation: coverage collection failed (#{e.class}: #{e.message})")
      nil
    end

    def emit(report, cfg)
      case cfg.report
      when :quiet then nil
      when :json then @out.puts(report.to_json)
      else @out.print(report.to_terminal)
      end
      return unless cfg.output

      File.write(cfg.output, JSON.pretty_generate(report.to_h))
      @out.puts("wrote #{cfg.output}") unless cfg.report == :quiet
    end

    def cpu_count
      File.read("/proc/cpuinfo").scan(/^processor/).size
    rescue StandardError
      Integer(ENV.fetch("NUMBER_OF_PROCESSORS", 1))
    end

    def help
      <<~HELP
        sabaku #{VERSION} - mutation testing for minitest

          sabaku run [paths]     mutate, run the covering tests, report
          sabaku list [paths]    show the mutants without running them
          sabaku doctor          report the environment

        Common options:
          --jobs=N                   mutants in flight at once
          --timeout=SEC              per-mutant deadline (default 5)
          --operators=aor,ror,...    enabled operators
          --per-line=N|all           mutants kept per line (default 1; all = mutant depth)
          --diff=PATH                only mutate the lines in {"path" => [lines]}
          --since=REV                only mutate lines changed since a git revision
          --fail-fast                stop at the first surviving mutant
          --[no-]baseline            refuse to score a suite that is already red (default on)
          --[no-]weak                dry-run probes that decide uninfected survivors
          --kill-matrix              run every selected test against each killed mutant and
                                     report redundant tests (the score does not change)
          --kill-matrix-scope=class|suite
                                     a test is redundant only next to tests of its own class
                                     (default), or next to any test in the suite
          --kill-matrix-focus=GLOB   sweep and judge only the test classes in these files
                                     (repeatable; needs scope class)
          --sweep-timeout=SEC        deadline for one kill-matrix sweep (default: --timeout)
          --env=KEY=VALUE            ENV set before the suite loads (repeatable)
          --require=PATH             require after coverage starts, before the tests
          --setup=PATH               Ruby file with boot hooks for Rails and friends
          --tests=GLOB               test files to load (repeatable; SABAKU_TEST_GLOB sets one)
          --isolation=fork|process   fork from a preloaded suite, or a fresh process
          --report=terminal|json     output format
          --output=PATH              write the JSON report
          --min-score=PCT            exit 1 when the reported score is below this

        Exit codes: 0 ok, 1 when the reported score is below --min-score,
                    2 error, or any mutant that produced no result.
      HELP
    end
  end
end
