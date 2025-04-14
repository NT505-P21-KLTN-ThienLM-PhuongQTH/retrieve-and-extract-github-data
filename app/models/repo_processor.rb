class RepoProcessor
    include GHTorrent::Settings
    include GHTorrent::Logging
    include GHTorrent::Commands::FullRepoRetriever

    def initialize
        @settings = config # Đọc từ settings.rb
        @persister = GHTorrent::MongoPersister.new(@settings)
        @ght = GHTorrent::GHTorrent.new(@settings)
    end

    def retrieve_full_repo(owner, repo)
        super(owner, repo)
    end
end