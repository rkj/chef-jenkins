#
# Cookbook Name:: jenkins
# Based on hudson
# Recipe:: default
#
# Author:: Doug MacEachern <dougm@vmware.com>
# Author:: Fletcher Nichol <fnichol@nichol.ca>
#
# Copyright 2010, VMware, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

pkey = "#{node[:jenkins][:server][:home]}/.ssh/id_rsa"
tmp = "/tmp"

user node[:jenkins][:server][:user] do
  home node[:jenkins][:server][:home]
end

directory node[:jenkins][:server][:home] do
  recursive true
  owner node[:jenkins][:server][:user]
  group node[:jenkins][:server][:group]
end

directory "#{node[:jenkins][:server][:home]}/.ssh" do
  mode 0700
  owner node[:jenkins][:server][:user]
  group node[:jenkins][:server][:group]
end

execute "ssh-keygen -f #{pkey} -N ''" do
  user  node[:jenkins][:server][:user]
  group node[:jenkins][:server][:group]
  not_if { File.exists?(pkey) }
end

ruby_block "store jenkins ssh pubkey" do
  block do
    node.set[:jenkins][:server][:pubkey] = File.open("#{pkey}.pub") { |f| f.gets }
  end
end

directory "#{node[:jenkins][:server][:home]}/plugins" do
  owner node[:jenkins][:server][:user]
  group node[:jenkins][:server][:group]
  only_if { node[:jenkins][:server][:plugins].size > 0 }
end

node[:jenkins][:server][:plugins].each do |name|
  remote_file "#{node[:jenkins][:server][:home]}/plugins/#{name}.hpi" do
    source "#{node[:jenkins][:mirror]}/latest/#{name}.hpi"
    backup false
    owner node[:jenkins][:server][:user]
    group node[:jenkins][:server][:group]
  end
end

case node.platform
when "ubuntu", "debian"
  # See http://jenkins-ci.org/debian/

  case node.platform
  when "debian"
    remote = "#{node[:jenkins][:mirror]}/latest/debian/jenkins.deb"
    package_provider = Chef::Provider::Package::Dpkg

    package "daemon"
    # These are both dependencies of the jenkins deb package
    package "jamvm"
    package "openjdk-6-jre"

    package "psmisc"

    remote_file "#{tmp}/jenkins-ci.org.key" do
      source "#{node[:jenkins][:mirror]}/debian/jenkins-ci.org.key"
    end

    execute "add-jenkins-key" do
      command "apt-key add #{tmp}/jenkins-ci.org.key"
      action :nothing
    end

  when "ubuntu"
    package_provider = Chef::Provider::Package::Apt
    package "curl"
    key_url = "http://pkg.jenkins-ci.org/debian/jenkins-ci.org.key"

    include_recipe "apt"
    include_recipe "java"

    cookbook_file "/etc/apt/sources.list.d/jenkins.list"

    execute "add-jenkins-key" do
      command "curl #{key_url} | apt-key add -"
      action :nothing
      notifies :run, "execute[apt-get update]", :immediately
    end
  end

  pid_file = "/var/run/jenkins/jenkins.pid"
  install_starts_service = true


when "centos", "redhat"
  #see http://jenkins-ci.org/redhat/

  remote = "#{node[:jenkins][:mirror]}/latest/redhat/jenkins.rpm"
  package_provider = Chef::Provider::Package::Rpm
  pid_file = "/var/run/jenkins.pid"
  install_starts_service = false

  execute "add-jenkins-key" do
    command "rpm --import #{node[:jenkins][:mirror]}/redhat/jenkins-ci.org.key"
    action :nothing
  end

end

#"jenkins stop" may (likely) exit before the process is actually dead
#so we sleep until nothing is listening on jenkins.server.port (according to netstat)
ruby_block "netstat" do
  block do
    10.times do
      if IO.popen("netstat -lnt").entries.select { |entry|
          entry.split[3] =~ /:#{node[:jenkins][:server][:port]}$/
        }.size == 0
        break
      end
      Chef::Log.debug("service[jenkins] still listening (port #{node[:jenkins][:server][:port]})")
      sleep 1
    end
  end
  action :nothing
end

service "jenkins" do
  supports [ :stop, :start, :restart, :status ]
  #"jenkins status" will exit(0) even when the process is not running
  status_command "test -f #{pid_file} && kill -0 `cat #{pid_file}`"
  action :nothing
end

if node.platform == "ubuntu"
  execute "setup-jenkins" do
    command "echo w00t"
    notifies :stop, "service[jenkins]", :immediately
    notifies :create, "ruby_block[netstat]", :immediately #wait a moment for the port to be released
    notifies :run, "execute[add-jenkins-key]", :immediately
    notifies :install, "package[jenkins]", :immediately
    unless install_starts_service
      notifies :start, "service[jenkins]", :immediately
    end
    creates "/usr/share/jenkins/jenkins.war"
  end
else
  local = File.join(tmp, File.basename(remote))

  remote_file local do
    source remote
    backup false
    notifies :stop, "service[jenkins]", :immediately
    notifies :create, "ruby_block[netstat]", :immediately #wait a moment for the port to be released
    notifies :run, "execute[add-jenkins-key]", :immediately
    notifies :install, "package[jenkins]", :immediately
    unless install_starts_service
      notifies :start, "service[jenkins]", :immediately
    end
    if node[:jenkins][:server][:use_head] #XXX remove when CHEF-1848 is merged
      action :nothing
    end
  end

  http_request "HEAD #{remote}" do
    only_if { node[:jenkins][:server][:use_head] } #XXX remove when CHEF-1848 is merged
    message ""
    url remote
    action :head
    if File.exists?(local)
      headers "If-Modified-Since" => File.mtime(local).httpdate
    end
    notifies :create, "remote_file[#{local}]", :immediately
  end
end

#this is defined after http_request/remote_file because the package
#providers will throw an exception if `source' doesn't exist
package "jenkins" do
  provider package_provider
  source local if node.platform != "ubuntu"
  action :nothing
end

#restart if this run only added new plugins
log "plugins updated, restarting jenkins" do
  #ugh :restart does not work, need to sleep after stop.
  notifies :stop, "service[jenkins]", :immediately
  notifies :create, "ruby_block[netstat]", :immediately
  notifies :start, "service[jenkins]", :immediately
  only_if do
    if File.exists?(pid_file)
      htime = File.mtime(pid_file)
      Dir["#{node[:jenkins][:server][:home]}/plugins/*.hpi"].select { |file|
        File.mtime(file) > htime
      }.size > 0
    end
  end
end

if node[:jenkins][:nginx][:proxy] && node[:jenkins][:nginx][:proxy] == "enable"
  include_recipe "nginx::source"

  if node[:jenkins][:nginx][:www_redirect] && 
      node[:jenkins][:nginx][:www_redirect] == "disable"
    www_redirect = false
  else
    www_redirect = true
  end

  template "#{node[:nginx][:dir]}/sites-available/jenkins.conf" do
    source      "nginx_jenkins.conf.erb"
    owner       'root'
    group       'root'
    mode        '0644'
    variables(
      :host_name        => node[:jenkins][:nginx][:host_name],
      :host_aliases     => node[:jenkins][:nginx][:host_aliases],
      :listen_ports     => node[:jenkins][:nginx][:listen_ports],
      :www_redirect     => www_redirect,
      :max_upload_size  => node[:jenkins][:nginx][:client_max_body_size]
    )

    if File.exists?("#{node[:nginx][:dir]}/sites-enabled/jenkins.conf")
      notifies  :restart, 'service[nginx]'
    end
  end

  nginx_site "jenkins.conf" do
    if node[:jenkins][:nginx][:proxy] && 
        node[:jenkins][:nginx][:proxy] == "disable"
      enable false
    else
      enable true
    end
  end
end

if platform?("redhat","centos","debian","ubuntu")
  include_recipe "iptables"
  iptables_rule "port_jenkins" do
    if node[:jenkins][:iptables_allow] == "enable"
      enable true
    else
      enable false
    end
  end
end
