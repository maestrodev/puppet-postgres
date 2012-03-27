# Class: postgres
#
# This module manages postgres
#
# Parameters:
#   $version:
#     Version of postgres to install
#   $password:
#     Password to use for created user. Use "" for no password
#
# Actions:
#
# Requires:
#
# Sample Usage: see postgres/README.markdown
#
# [Remember: No empty lines between comments and class definition]
class postgres ($version = $postgres_version, $password = $postgres_password,
                $datadir="/var/lib/pgsql/data") {
  # Common stuff
  include postgres::common

  # Handle version specified in site.pp (or default to postgresql) 
  $postgres_client = "postgresql${postgres::version}"
  $postgres_server = "postgresql${postgres::version}-server"

  package { [$postgres_client, $postgres_server]: 
    ensure => installed,
  }

  user { 'postgres':
    shell => '/bin/bash',
    ensure => 'present',
    comment => 'PostgreSQL Server',
    uid => '26',
    gid => '26',
    home => "/var/lib/pgsql",
    managehome => true,
    password => '!!',
  }

  group { 'postgres':
    ensure => 'present',
    gid => '26'
  }

}

# Initialize the database with the postgres_password password.
define postgres::initdb() {
  if $postgres::password == "" {
    exec {
        "InitDB":
          command => "/bin/chown postgres.postgres /var/lib/pgsql && /bin/su postgres -c \"/usr/bin/initdb $postgres::datadir -E UTF8\"",
          require =>  [User['postgres'],Package["postgresql${postgres::version}-server"]],
          unless => "/usr/bin/test -e $postgres::datadir/PG_VERSION",
    }
  } else {
    exec {
        "InitDB":
          command => "/bin/chown postgres.postgres /var/lib/pgsql && echo \"${postgres::password}\" > /tmp/ps && /bin/su  postgres -c \"/usr/bin/initdb $postgres::datadir --auth='password' --pwfile=/tmp/ps -E UTF8 \" && rm -rf /tmp/ps",
          require =>  [User['postgres'],Package["postgresql${postgres::version}-server"]],
          unless => "/usr/bin/test -e $postgres::datadir/PG_VERSION ",
    }
  }
}

# Start the service if not running
define postgres::enable {
  if ( $postgres::version != "" and $postgres::version >= "90" ) {
    $service = "postgresql-9.0"
  } else {
    $service = "postgresql"
  }
  service { postgresql:
    name => $service,
    ensure => running,
    enable => true,
    hasstatus => true,
    require => Exec["InitDB"],
  }
}


# Postgres host based authentication
define postgres::hba ($allowedrules){
  file { "$postgres::datadir/pg_hba.conf":
    content => template("postgres/pg_hba.conf.erb"),	
    owner  => "root",
    group  => "root",
    notify => Service["postgresql"],
 #   require => File["/var/lib/pgsql/.order"],
    require => Exec["InitDB"],
  }
}

define postgres::config ($listen="localhost")  {
  file {"$postgres::datadir/postgresql.conf":
    content => template("postgres/postgresql.conf.erb"),
    owner => postgres,
    group => postgres,
    notify => Service["postgresql"],
  #  require => File["/var/lib/pgsql/.order"],
    require => Exec["InitDB"],
  }
}

# Base SQL exec
define sqlexec($username, $password="", $database, $sql, $sqlcheck) {
  file{ "/tmp/puppetsql-$name":
    owner => $username,
    group => $username,
    content => $sql,
    mode => 0600,
    ensure => present,
  }  
  if $password == "" {
    exec{ "psql -h localhost --username=${username} $database -f /tmp/puppetsql-$name  >> /tmp/puppetsql-$name.sql.log 2>&1 && /bin/sleep 5":
      timeout     => 600,
      unless      => "psql -U $username $database -c $sqlcheck",
      require =>  [User['postgres'],Service[postgresql],File["/tmp/puppetsql-$name"]],
    }
  } else {
    exec{ "psql -h localhost --username=${username} $database -f /tmp/puppetsql-$name  >> /tmp/puppetsql-$name.sql.log 2>&1 && /bin/sleep 5":
      environment => "PGPASSWORD=${password}",
      timeout     => 600,
      unless      => "psql -U $username $database -c $sqlcheck",
      require =>  [User['postgres'],Service[postgresql],File["/tmp/puppetsql-$name"]],
    }
  }
}

# Create a Postgres user
define postgres::createuser($passwd) {
  # if user doesn't exist, create it
  sqlexec{ "createuser-${name}":
    password => $postgres::password,
    username => "postgres",
    database => "postgres",
    sql      => "CREATE ROLE ${name} WITH LOGIN PASSWORD '${passwd}';",
    sqlcheck => "\"SELECT usename FROM pg_user WHERE usename = '${name}'\" | grep ${name}",
    require  =>  Service[postgresql],
  }
}

# Define a Postgres user.
# Not optimal as password will be changed all the time, no way to check if password is already set to a specific value
define postgres::user($passwd) {
  postgres::createuser{ $name: passwd => $passwd } ->
  # if user exists, ensure password is correctly set (useful for updates)
  sqlexec{ "updateuser-${name}":
    password => $postgres::password,
    username => "postgres",
    database => "postgres",
    sql      => "ALTER ROLE ${name} WITH PASSWORD '${passwd}';",
    sqlcheck => "fail", # trigger the SQL anyway
  }
}

# Create a Postgres db
define postgres::createdb($owner) {
  sqlexec{ $name:
    password => $postgres::password,
    username => "postgres",
    database => "postgres",
    sql => "CREATE DATABASE $name WITH OWNER = $owner ENCODING = 'UTF8';",
    sqlcheck => "\"SELECT datname FROM pg_database WHERE datname ='$name'\" | grep $name",
    require => Service[postgresql],
  }
}
