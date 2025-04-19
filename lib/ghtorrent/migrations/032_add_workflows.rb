require 'sequel'

Sequel.migration do
  up do
    puts("Creating table workflows")
    create_table :workflows do
      primary_key :id
      Integer :github_id, :null => false, :unique => true # GitHub workflow ID
      String :name, :null => false
      String :path, :null => false # Path to YAML file (e.g., .github/workflows/ci.yml)
      String :state, :null => false # active, deleted, disabled
      foreign_key :project_id, :projects, :null => false
      String :ext_ref_id, :null => false, :size => 24, :default => "0"
      DateTime :created_at, :null => false, :default => Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, :null => false, :default => Sequel::CURRENT_TIMESTAMP
    end

    puts("Creating table workflow_runs")
    create_table :workflow_runs do
      primary_key :id
      Integer :github_id, :null => false, :unique => true # GitHub run ID
      foreign_key :workflow_id, :workflows, :null => false
      String :commit_sha, :size => 40, :null => false # Link to commits.sha
      String :status, :null => false # queued, in_progress, completed
      String :conclusion # success, failure, cancelled, etc.
      Integer :run_number, :null => false
      String :ext_ref_id, :null => false, :size => 24, :default => "0"
      DateTime :created_at, :null => false, :default => Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, :null => false, :default => Sequel::CURRENT_TIMESTAMP
      index [:workflow_id]
      index [:commit_sha]
    end

    puts("Adding index on workflow_runs.commit_sha")
    add_index :workflow_runs, :commit_sha
  end

  down do
    puts("Dropping table workflow_runs")
    drop_table :workflow_runs
    puts("Dropping table workflows")
    drop_table :workflows
  end
end