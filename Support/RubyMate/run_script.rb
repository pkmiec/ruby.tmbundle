require "#{ENV["TM_SUPPORT_PATH"]}/lib/tm/executor"
require "#{ENV["TM_SUPPORT_PATH"]}/lib/tm/save_current_document"
require "pathname"
require 'fileutils'
require "yaml"

TextMate.save_if_untitled

def path_to_url_chunk(path)
  unless path == "untitled"
    prefix = ''
    2.times do
      begin
        file = Pathname.new(prefix + path).realpath.to_s
        return "url=file://#{e_url(file)}&amp;"
      rescue Errno::ENOENT
        # Hmm lets try to prefix with project directory
        prefix = "#{ENV['TM_PROJECT_DIRECTORY']}/"
      end
    end
  else
    ''
  end
end

def actual_path_name(path)
  prefix = ''
  2.times do
    begin
      file = Pathname.new(prefix + path).realpath.to_s
      url = '&amp;url=file://' + e_url(file)
      display_name = File.basename(file)
      return file, url, display_name
    rescue Errno::ENOENT
      # Hmm lets try to prefix with project directory
      prefix = "#{ENV['TM_PROJECT_DIRECTORY']}/"
    end
  end
  return path, '', path
end

rerun_root = File.join(ENV['TMPDIR'], 'rerun')
rerun_path = File.join(rerun_root, "#{ENV['TM_PROJECT_UUID']}.yml")
FileUtils.mkdir_p(rerun_root)

args           = []
use_hashbang   = !ENV.has_key?('TM_RUBY')
cmd            = [ENV['TM_RUBY'] || 'ruby', '-rcatch_exception']
test_root      = nil
is_test_script = !(ENV["TM_FILEPATH"].match(/(?:\b|_)(?:tc|ts|test)(?:\b|_)/).nil? and
  File.read(ENV["TM_FILEPATH"]).match(/\brequire\b.+(?:test\/unit|test_helper)/).nil?)
verb           = "Running"
noun           = ENV['TM_DISPLAYNAME']

if ARGV.first == "--rerun" && File.exist?(rerun_path)
  rerun_options = YAML.load(File.read(rerun_path))

  cmd            = rerun_options['cmd']
  args           = rerun_options['args']
  use_hashbang   = rerun_options['use_hashbang']
  test_root      = rerun_options['test_root']
  is_test_script = rerun_options['is_test_script']
  noun           = rerun_options['noun']
  verb           = "Re-running"
  
else
  # For Run focused unit test, find the name of the test the user wishes to run.
  if ARGV.first == "--name="
    n = ENV['TM_LINE_NUMBER'].to_i

    should, spec, context, name, test_name = nil, nil, nil

    File.open(ENV['TM_FILEPATH']) do |f|
      # test/unit
      lines     = f.read.split("\n")[0...n].reverse
      name      = lines.find { |line| line =~ /^\s*def test[_a-z0-9]*[\?!]?/i }.to_s.sub(/^\s*def (.*?)\s*$/) { $1 }
      # test helper
      test_name = $2 || $3 if lines.find { |line| line =~ /^\s*test\s+('(.*)'|"(.*)")+\s*(\{|do)/ }
      # test/spec.
      spec      = $3 || $4 if lines.find { |line| line =~ /^\s*(specify|it)\s+('(.*)'|"(.*)")+\s*(\{|do)/ }
      context   = $3 || $4 if lines.find { |line| line =~ /^\s*(context|describe)\s+('(.*)'|"(.*)")+\s*(\{|do)/ }
      # shoulda.
      should    = $3 || $4 if lines.find { |line| line =~ /^\s*(should)\s+('(.*)'|"(.*)")+\s*(\{|do)/ }
      context   = $3 || $4 if lines.find { |line| line =~ /^\s*(context)\s+('(.*)'|"(.*)")+\s*(\{|do)/ }
    end
  
    if name and !name.empty?
      args << "--name=#{name}"
    elsif test_name and !test_name.empty?
      args << "--name=test_#{test_name.gsub(/\s+/,'_')}"
    elsif spec and !spec.empty? and context and !context.empty?
      args << %Q{--name="/test_spec \\{.*#{context}\\} \\d{3} \\[#{spec}\\]/"}
    elsif should and !should.empty? and context and !context.empty?
      test_name = "#{context} should #{should}".gsub(/[\$\?\+\.\s\'\"\(\)]/,'.?')
      args << "--name=/#{test_name}/"
    else
      puts "Error:  This doesn't appear to be a TestCase or spec."
      exit
    end
  end

  if is_test_script and not ENV['TM_FILE_IS_UNTITLED']
    path_ary = ENV['TM_FILEPATH'].split("/")
    if index = path_ary.rindex("test")
      test_root  = File.expand_path(File.join(*(path_ary[0..-2] + [".."] * (path_ary.length - index - 1))))
      # test_path = "#{File.join(*path_ary[0..index])}:#{File.join(*path_ary[0..-2])}"
      # lib_path  = File.join(test_root, "lib")
    
      spring_path = File.join(test_root, "bin", "testunit")
      if File.exist?(spring_path)
        cmd << spring_path
      else
        cmd << "-Itest"
        # if File.exist? lib_path
        #   cmd << "-I#{lib_path}:#{test_path}"
        # else
        #   cmd << "-I#{test_path}"
        # end
      end
    
    end
  end

  cmd << ENV["TM_FILEPATH"]

  rerun_options = {
    'is_test_script' => is_test_script,
    'test_root'      => test_root,
    'cmd'            => cmd,
    'args'           => args,
    'use_hashbang'   => use_hashbang,
    'noun'           => noun,
  }

  File.open(rerun_path, 'w+') { |out| YAML.dump(rerun_options, out ) }
end

Dir.chdir(test_root) if test_root # in order for ruby version to be correct
TextMate::Executor.run( cmd, :chdir => test_root,
                             :version_args => ["--version"],
                             :use_hashbang => use_hashbang,
                             :create_error_pipe => true,
                             :script_args  => args,
                             :verb => verb,
                             :noun => noun ) do |line, type|
  #  
  if is_test_script and type == :out
    
    if line =~ /\A[.EF]+\Z/
      line.gsub!(/([.])/, "<span class=\"test ok\">\\1</span>")
      line.gsub!(/([EF])/, "<span class=\"test fail\">\\1</span>")
      line + "<br/>\n"
    else
      if line =~ /^(\s+)(\S.*?):(\d+)(?::in\s*`(.*?)')?/
        indent, file, line, method = $1, $2, $3, $4
        url, display_name = '', 'untitled document';
        unless file == "untitled"
          indent += " " if file.sub!(/^\[/, "")
          if file == '(eval)'
            display_name = file
          else
            file, url, display_name = actual_path_name(file)
          end
        end
        out = indent
        out += "<a class='near' href='txmt://open?line=#{line + url}'>" unless url.empty?
        out += (method ? "method #{CGI::escapeHTML method}" : '<em>at top level</em>')
        out += "</a>" unless url.empty?
        out += " in <strong>#{CGI::escapeHTML display_name}</strong> at line #{line}<br/>"
        out
      elsif line =~ /test\_(should\_[\w\_]+)\((\w+)\)\s+\[([\w\_\/\.]+)\:(\d+)\]\:/ # shoulda 2.11.3 output test_should_fulfill(SomeTest) [test/unit/some_test.rb:42]:
        spec, mod, file, line = $1, $2, $3, $4
        spec.gsub!('_',' ')
        "<span><a href=\"txmt://open?#{path_to_url_chunk(file)}line=#{line}\">#{mod}: #{spec}</a></span>:#{line}<br/>"
      elsif line =~ /(\[[^\]]+\]\([^)]+\))\s+\[([\w\_\/\.]+)\:(\d+)\]/ # [spec](file) some text [function_name:line_no]
        spec, file, line = $1, $2, $3, $4
        "<span><a href=\"txmt://open?#{path_to_url_chunk(file)}line=#{line}\">#{spec}</a></span>:#{line}<br/>"
      elsif line =~ /([\w\_]+).*\[([\w\_\/\.]+)\:(\d+)\]/   # whatever_message....[function_name/.whatever:line_no]
        method, file, line = $1, $2, $3
        "<span><a href=\"txmt://open?#{path_to_url_chunk(file)}line=#{line}\">#{method}</a></span>:#{line}<br/>"
      elsif line =~ /^\d+ tests, \d+ assertions, (\d+) failures, (\d+) errors\b.*/
        "<div class=\"test #{$1 + $2 == "00" ? "ok" : "fail"}\">#{$&}</div>\n"
      end
    end
  end
end
