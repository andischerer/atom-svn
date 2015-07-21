SvnRepository = require './svn-repository'
# Checks whether a valid `.svn` directory is contained within the given
# directory or one of its ancestors. If so, a Directory that corresponds to the
# `.svn` folder will be returned. Otherwise, returns `null`.
#
# * `directory` {Directory} to explore whether it is part of a SVN repository.
findSvnRepoRootDirectorySync = (directory) ->
  # TODO: Fix node-pathwatcher/src/directory.coffee so the following methods
  # can return cached values rather than always returning new objects:
  # getParent(), getFile(), getSubdirectory().
  svnDir = directory.getSubdirectory('.svn')
  if svnDir.existsSync?() and isValidSvnDirectorySync(svnDir)
    return directory
  else if directory.isRoot()
    return null
  else
    findSvnRepoRootDirectorySync(directory.getParent())

# Returns a boolean indicating whether the specified directory represents a SVN
# repository.
#
# * `directory` {Directory} whose base name is `.svn`.
isValidSvnDirectorySync = (directory) ->
  # To decide whether a directory has a valid .svn folder
  return directory.getSubdirectory('pristine').existsSync() and
      (directory.getFile('wc.db').existsSync() or directory.getFile('entries').existsSync())

# Provider that conforms to the atom.repository-provider@0.1.0 service.
module.exports =
class SvnRepositoryProvider
  constructor: (@project) ->
    # Keys are real paths to the rootPath of SVN-Repo
    # Values are the corresponding SvnRepository objects.
    @pathToRepository = {}

  # Returns a {Promise} that resolves with either:
  # * {SvnRepository} if the given directory has a SVN repository.
  # * `null` if the given directory does not have a SVN repository.
  repositoryForDirectory: (directory) ->
    # TODO: Currently, this method is designed to be async, but it relies on a
    # synchronous API. It should be rewritten to be truly async.
    Promise.resolve(@repositoryForDirectorySync(directory))

  # Returns either:
  # * {SvnRepository} if the given directory has a SVN repository.
  # * `null` if the given directory does not have a SVN repository.
  repositoryForDirectorySync: (directory) ->
    # Only one SvnRepository should be created for each .svn folder. Therefore,
    # we must check directory and its parent directories to find the nearest
    # .svn folder.
    svnRepoRootDir = findSvnRepoRootDirectorySync(directory)
    unless svnRepoRootDir
      return null

    svnDirPath = svnRepoRootDir.getPath()
    repo = @pathToRepository[svnDirPath]
    unless repo
      repo = SvnRepository.open(svnDirPath, project: @project)
      return null unless repo
      # @TODO: handle multiple projects with different working directories for the same svn-repository
      # atm. the first project workingDir folder wins
      repo.setWorkingDirectory(directory.getPath())
      repo.onDidDestroy(=> delete @pathToRepository[svnDirPath])
      @pathToRepository[svnDirPath] = repo
      repo.refreshIndex()
      repo.refreshStatus()

    return repo
