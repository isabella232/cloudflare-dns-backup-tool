#!/usr/bin/ruby
require 'cloudflare'

require 'json'
require 'pathname'
require 'set'
require 'open3'
require 'tempfile'

# Get all records, even if > 180 in number
def records(cf, zone)
  records = []
  loop do
    resp = cf.rec_load_all(zone, records.size)
    recset = resp['response']['recs']
    records.concat(recset['objs'])
    break unless recset['has_more']
  end
  records
end

def write_json(dir, filename, obj)
  path = dir.join(filename + '.json')
  IO.write(path.to_s, JSON.pretty_generate(obj))
  return path
end

def backup(cf, dir, key)
  # Fetch everything
  zones = cf.zone_load_multi
  recs = {}
  zones['response']['zones']['objs'].each do |zone|
    name = zone['zone_name']
    recs[name] = records(cf, name)
  end

  # Put it where it belongs
  dir = Pathname.new(dir)
  dir.mkpath
  written = Set.new
  written << write_json(dir, 'zones', zones)
  recs.each { |z, rs| written << write_json(dir, z + '.zone', rs) }

  # Remove old files
  dir.find do |file|
    next if dir == file
    if file.basename.to_s == '.git'
      Find.prune
      next
    end
    file.unlink unless written.include? file
  end

  # Auto-commit
  auto_commit(dir, key) if dir.join('.git').exist?
end

def auto_commit(dir, key)
  # Setup GIT_SSH appropriately
  old_ssh = ENV['GIT_SSH']
  ssh_wrapper = Tempfile.new('git-ssh', :mode => 0700)
  ssh_wrapper.chmod(0700)
  ssh_wrapper.puts(<<-EOF)
#!/bin/sh
exec ssh -i #{key.realpath.to_s} "$@"
EOF
  ssh_wrapper.close
  ENV['GIT_SSH'] = ssh_wrapper.path

  begin
    Dir.chdir(dir.to_s) do
      # Add new/changed files
      added = IO.popen(%w[git ls-files --exclude-standard -o -m -z]) \
        .each_line("\0").map { |n| n.chomp("\0") }
      system('git', 'add', *added) unless added.empty?

      unless system(*%w[git diff --cached --quiet])
        system(*%w[git commit --quiet -am], "Autocommit at " + Time.now.to_s)
        system(*%w[git push --quiet])
      end
    end
  ensure
    ENV['GIT_SSH'] = old_ssh
    ssh_wrapper.unlink
  end
end

email, token, dir = ARGV
cf = CloudFlare::connection(token, email)
key = Pathname.new(__FILE__).parent.join('id_rsa')
backup(cf, dir, key)
