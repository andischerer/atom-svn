{Emitter, Disposable, CompositeDisposable} = require 'event-kit'

SvnUtils = require './svn-utils'

module.exports =
class SvnRepository

  devMode: atom.inDevMode()
  workingDirectory: ''

  ###
  Section: Construction and Destruction
  ###

  # Public: Creates a new SvnRepository instance.
  #
  # * `path` The {String} path to the SVN repository to open.
  # * `options` An optional {Object} with the following keys:
  #   * `refreshOnWindowFocus` A {Boolean}, `true` to refresh the index and
  #     statuses when the window is focused.
  #
  # Returns a {SvnRepository} instance or `null` if the repository could not be opened.
  @open: (path, options) ->
    return null unless path
    console.log('SVN', 'svn-repository', '@open', path, options) if @devMode
    try
      new SvnRepository(path, options)
    catch
      null

  constructor: (path, options={}) ->
    fakeAsync = (fn) -> new Promise((resolve) -> setTimeout((-> resolve(fn())), 0))
    @async =
      onDidChangeStatus: (cb) => @onDidChangeStatus(cb)
      onDidChangeStatuses: (cb) => @onDidChangeStatuses(cb)
      getCachedUpstreamAheadBehindCount: (path) => @getCachedUpstreamAheadBehindCount(path)
      getShortHead: (path) => fakeAsync(=> @getShortHead())
      getCachedPathStatus: (path) => fakeAsync(=> @getCachedPathStatus(path))
      getLineDiffs: (path, text) => fakeAsync(=> @getLineDiffs(path, text))
      isStatusNew: (status) => fakeAsync(=> @isStatusNew(status))
      getWorkingDirectory: () => fakeAsync(=> @getWorkingDirectory())
      getCachedPathStatuses: () =>
        # Our @statuses object uses absolute paths,
        # the method should return relative (to working directory) paths
        statuses = {}
        workingDirectory = @slashPath(@getWorkingDirectory())
        for filepath of @statuses
          statuses[filepath.replace(workingDirectory, "")] = @statuses[filepath]
        statuses

    @emitter = new Emitter
    @subscriptions = new CompositeDisposable

    @repo = SvnUtils.open(path)
    unless @repo?
      throw new Error("No SVN repository found searching path: #{path.path}")

    @statuses = {}
    @upstream = {ahead: 0, behind: 0}

    @cachedIgnoreStatuses = []
    @cachedSvnFileContent = {}

    {@project, refreshOnWindowFocus} = options

    refreshOnWindowFocus ?= true
    if refreshOnWindowFocus
      onWindowFocus = =>
        @refreshIndex()
        @refreshStatus()

      window.addEventListener 'focus', onWindowFocus
      @subscriptions.add new Disposable(-> window.removeEventListener 'focus', onWindowFocus)

    if @project?
      @project.getBuffers().forEach (buffer) => @subscribeToBuffer(buffer)
      @subscriptions.add @project.onDidAddBuffer (buffer) => @subscribeToBuffer(buffer)

  # Public: Destroy this {SvnRepository} object.
  #
  # This destroys any tasks and subscriptions and releases the SvnRepository
  # object
  destroy: ->
    console.log('SVN', 'svn-repository', 'destroy') if @devMode
    if @emitter?
      @emitter.emit 'did-destroy'
      @emitter.dispose()
      @emitter = null

    # if @statusTask?
      # @statusTask.terminate()
      # @statusTask = null

    if @repo?
      # @repo.release()
      @repo = null

    if @subscriptions?
      @subscriptions.dispose()
      @subscriptions = null

  ###
  Section: Event Subscription
  ###

  # Public: Invoke the given callback when this SvnRepository's destroy() method
  # is invoked.
  onDidDestroy: (callback) ->
    @emitter.on 'did-destroy', callback

  # Public: Invoke the given callback when a specific file's status has
  # changed. When a file is updated, reloaded, etc, and the status changes, this
  # will be fired.
  #
  # * `callback` {Function}
  #   * `event` {Object}
  #     * `path` {String} the old parameters the decoration used to have
  #     * `pathStatus` {Number} representing the status. This value can be passed to
  #       {::isStatusModified} or {::isStatusNew} to get more information.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  onDidChangeStatus: (callback) ->
    @emitter.on 'did-change-status', callback

  # Public: Invoke the given callback when a multiple files' statuses have
  # changed. For example, on window focus, the status of all the paths in the
  # repo is checked. If any of them have changed, this will be fired. Call
  # {::getPathStatus(path)} to get the status for your path of choice.
  #
  # * `callback` {Function}
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  onDidChangeStatuses: (callback) ->
    @emitter.on 'did-change-statuses', callback

  ###
  Section: Repository Details
  ###

  # Public: A {String} indicating the type of version control system used by
  # this repository.
  #
  # Returns `"svn"`.
  getType: -> 'svn'

  # Public: Returns the {String} path of the repository.
  getPath: ->
    @path ?= @getRepo().getPath()

  # Public: Sets the {String} working directory path of the repository.
  setWorkingDirectory: (workingDirectory) ->
    console.log('SVN', 'svn-repository', 'setWorkingDirectory', workingDirectory) if @devMode
    @workingDirectory = workingDirectory

  # Public: Returns the {String} working directory path of the repository.
  getWorkingDirectory: ->
    console.log('SVN', 'svn-repository', 'getWorkingDirectory', @workingDirectory) if @devMode
    return @workingDirectory

  # Public: Returns true if at the root, false if in a subfolder of the
  # repository.
  isProjectAtRoot: ->
    console.log('SVN', 'svn-repository', 'isProjectAtRoot', @project?.relativize(@getPath()) is '') if @devMode
    @projectAtRoot ?= @project?.relativize(@getPath()) is ''

  # Public: Makes a path relative to the repository's working directory.
  relativize: (path) -> null

  # Slash win32 path
  slashPath: (path) ->
    return path unless path
    if process.platform is 'win32'
      return path.replace(/\\/g, '/')
    else
      return path

  # Public: Returns true if the given branch exists.
  hasBranch: (branch) -> null

  # Public: Retrieves a shortened version of the HEAD reference value.
  #
  # This removes the leading segments of `refs/heads`, `refs/tags`, or
  # `refs/remotes`.  It also shortens the SHA-1 of a detached `HEAD` to 7
  # characters.
  #
  # * `path` An optional {String} path in the repository to get this information
  #   for, only needed if the repository contains submodules.
  #
  # Returns a {String}.
  getShortHead: (path) -> @getRepo().getShortHead()

  # Public: Is the given path a submodule in the repository?
  #
  # * `path` The {String} path to check.
  #
  # Returns a {Boolean}.
  isSubmodule: (path) -> null

  # Public: Returns the number of commits behind the current branch is from the
  # its upstream remote branch.
  #
  # * `reference` The {String} branch reference name.
  # * `path`      The {String} path in the repository to get this information for,
  #   only needed if the repository contains submodules.
  getAheadBehindCount: (reference, path) -> null

  # Public: Get the cached ahead/behind commit counts for the current branch's
  # upstream branch.
  #
  # * `path` An optional {String} path in the repository to get this information
  #   for, only needed if the repository has submodules.
  #
  # Returns an {Object} with the following keys:
  #   * `ahead`  The {Number} of commits ahead.
  #   * `behind` The {Number} of commits behind.
  getCachedUpstreamAheadBehindCount: (path) -> {ahead: 0, behind: 0}

  # Public: Returns the svn property value specified by the key.
  #
  # * `path` An optional {String} path in the repository to get this information
  #   for, only needed if the repository has submodules.
  getConfigValue: (key, path) -> null

  # Public: Returns the origin url of the repository.
  #
  # * `path` (optional) {String} path in the repository to get this information
  #   for, only needed if the repository has submodules.
  getOriginUrl: (path) -> null

  # Public: Returns the upstream branch for the current HEAD, or null if there
  # is no upstream branch for the current HEAD.
  #
  # * `path` An optional {String} path in the repo to get this information for,
  #   only needed if the repository contains submodules.
  #
  # Returns a {String} branch name such as `refs/remotes/origin/master`.
  getUpstreamBranch: (path) -> null

  # Public: Gets all the local and remote references.
  #
  # * `path` An optional {String} path in the repository to get this information
  #   for, only needed if the repository has submodules.
  #
  # Returns an {Object} with the following keys:
  #  * `heads`   An {Array} of head reference names.
  #  * `remotes` An {Array} of remote reference names.
  #  * `tags`    An {Array} of tag reference names.
  getReferences: (path) -> null

  # Public: Returns the current {String} SHA for the given reference.
  #
  # * `reference` The {String} reference to get the target of.
  # * `path` An optional {String} path in the repo to get the reference target
  #   for. Only needed if the repository contains submodules.
  getReferenceTarget: (reference, path) -> null

  ###
  Section: Reading Status
  ###

  # Public: Returns true if the given path is modified.
  isPathModified: (path) -> @isStatusModified(@getPathStatus(path))

  # Public: Returns true if the given path is new.
  isPathNew: (path) -> @isStatusNew(@getPathStatus(path))

  # Public: Is the given path ignored?
  #
  # Returns a {Boolean}.
  # isPathIgnored: (path) -> @isStatusIgnored(@getPathStatus(path))
  isPathIgnored: (path) -> @cachedIgnoreStatuses.indexOf(@slashPath(path)) != -1

  # Public: Get the status of a directory in the repository's working directory.
  #
  # * `path` The {String} path to check.
  #
  # Returns a {Number} representing the status. This value can be passed to
  # {::isStatusModified} or {::isStatusNew} to get more information.
  getDirectoryStatus: (directoryPath) ->
    console.log('SVN', 'svn-repository', 'getDirectoryStatus', directoryPath) if @devMode
    directoryPath = "#{@slashPath(directoryPath)}/"
    directoryStatus = 0
    for path, status of @statuses
      directoryStatus |= status if path.indexOf(directoryPath) is 0
    return directoryStatus

  # Public: Get the status of a single path in the repository.
  #
  # `path` A {String} repository-relative path.
  #
  # Returns a {Number} representing the status. This value can be passed to
  # {::isStatusModified} or {::isStatusNew} to get more information.
  getPathStatus: (path) ->
    console.log('SVN', 'svn-repository', 'getPathStatus', path) if @devMode
    repo = @getRepo()
    relativePath = @slashPath(path)
    currentPathStatus = @statuses[relativePath] ? 0
    pathStatus = repo.getPathStatus(relativePath) ? 0
    pathStatus = 0 if repo.isStatusIgnored(pathStatus)
    if pathStatus > 0
      @statuses[relativePath] = pathStatus
    else
      delete @statuses[relativePath]
    if currentPathStatus isnt pathStatus
      @emitter.emit 'did-change-status', {path, pathStatus}
    return pathStatus

  # Public: Get the cached status for the given path.
  #
  # * `path` A {String} path in the repository, relative or absolute.
  #
  # Returns a status {Number} or null if the path is not in the cache.
  getCachedPathStatus: (path) ->
    return unless path
    console.log('SVN', 'svn-repository', 'getCachedPathStatus', path, @statuses[@slashPath(path)]) if @devMode
    return @statuses[@slashPath(path)]

  # Public: Returns true if the given status indicates modification.
  isStatusModified: (status) -> @getRepo().isStatusModified(status)

  # Public: Returns true if the given status indicates a new path.
  isStatusNew: (status) -> @getRepo().isStatusNew(status)

  # Public: Returns true if the given status is ignored.
  isStatusIgnored: (status) -> @getRepo().isStatusIgnored(status)

  ###
  Section: Retrieving Diffs
  ###

  # Retrieves the file content from latest svn revision and cache it.
  #
  # * `path` The {String} path for retrieving file contents.
  #
  # Returns a {String} with the filecontents
  getCachedSvnFileContent: (path) ->
    slashedPath = @slashPath(path)
    if (!@cachedSvnFileContent[slashedPath])
      repo = @getRepo()
      @cachedSvnFileContent[slashedPath] = repo.getSvnCat(path)
    return @cachedSvnFileContent[slashedPath]

  # Public: Retrieves the number of lines added and removed to a path.
  #
  # This compares the working directory contents of the path to the `HEAD`
  # version.
  #
  # * `path` The {String} path to check.
  #
  # Returns an {Object} with the following keys:
  #   * `added` The {Number} of added lines.
  #   * `deleted` The {Number} of deleted lines.
  getDiffStats: (path) ->
    return @getRepo().getDiffStats(@slashPath(path), @getCachedSvnFileContent(path))

  # Public: Retrieves the line diffs comparing the `HEAD` version of the given
  # path and the given text.
  #
  # * `path` The {String} path relative to the repository.
  # * `text` The {String} to compare against the `HEAD` contents
  #
  # Returns an {Array} of hunk {Object}s with the following keys:
  #   * `oldStart` The line {Number} of the old hunk.
  #   * `newStart` The line {Number} of the new hunk.
  #   * `oldLines` The {Number} of lines in the old hunk.
  #   * `newLines` The {Number} of lines in the new hunk
  getLineDiffs: (path, text) ->
    # Ignore eol of line differences on windows so that files checked in as
    # LF don't report every line modified when the text contains CRLF endings.
    options = ignoreEolWhitespace: process.platform is 'win32'
    repo = @getRepo()
    return repo.getLineDiffs(@getCachedSvnFileContent(path), text, options)

  ###
  Section: Checking Out
  ###

  # Public: Restore the contents of a path in the working directory and index
  # to the version at `HEAD`.
  #
  # This is essentially the same as running:
  #
  # ```sh
  #   git reset HEAD -- <path>
  #   git checkout HEAD -- <path>
  # ```
  #
  # * `path` The {String} path to checkout.
  #
  # Returns a {Boolean} that's true if the method was successful.
  checkoutHead: (path) -> null

  # Public: Checks out a branch in your repository.
  #
  # * `reference` The {String} reference to checkout.
  # * `create`    A {Boolean} value which, if true creates the new reference if
  #   it doesn't exist.
  #
  # Returns a Boolean that's true if the method was successful.
  checkoutReference: (reference, create) -> null

  ###
  Section: Private
  ###

 # Subscribes to buffer events.
  subscribeToBuffer: (buffer) ->
    getBufferPathStatus = =>
      if path = buffer.getPath()
        @getPathStatus(path)

    bufferSubscriptions = new CompositeDisposable
    bufferSubscriptions.add buffer.onDidSave(getBufferPathStatus)
    bufferSubscriptions.add buffer.onDidReload(getBufferPathStatus)
    bufferSubscriptions.add buffer.onDidChangePath(getBufferPathStatus)
    bufferSubscriptions.add buffer.onDidDestroy =>
      bufferSubscriptions.dispose()
      @subscriptions.remove(bufferSubscriptions)
    @subscriptions.add(bufferSubscriptions)
    return

  # Subscribes to editor view event.
  checkoutHeadForEditor: (editor) -> null

 # Returns the corresponding {Repository}
  getRepo: () ->
    if @repo?
      return @repo
    else
      throw new Error("Repository has been destroyed")

  # Reread the index to update any values that have changed since the
  # last time the index was read.
  refreshIndex: -> null

  # Refreshes the current svn status in an outside process and asynchronously
  # updates the relevant properties.
  refreshStatus: ->
    console.log('SVN', 'svn-repository', 'refreshStatus') if @devMode

    new Promise((resolve, reject) =>
      statusesDidChange = false
      if @getRepo().checkRepositoryHasChanged()
        @statuses = {}
        @cachedSvnFileContent = {}
        # cache recursiv ignore statuses
        @cachedIgnoreStatuses = @getRepo().getRecursiveIgnoreStatuses()
        statusesDidChange = true

      for {status, path} in @getRepo().getStatus()
        slashedPath = @slashPath(path)
        if @statuses[slashedPath] != status
          @statuses[slashedPath] = status
          statusesDidChange = true

      if statusesDidChange then @emitter.emit 'did-change-statuses'
    )
