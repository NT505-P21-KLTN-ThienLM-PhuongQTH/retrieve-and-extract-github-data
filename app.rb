require_relative "./app/config/environment"
require_relative "./app/controllers/repo_controller"

class Application < App::Base
  use RepoController
end

Application.run! if $PROGRAM_NAME == __FILE__