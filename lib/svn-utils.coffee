fs = require 'fs'
pathlib = require 'path'
util = require 'util'
urlParser = require 'url'
$ = require 'jquery'
{spawnSync} = require 'child_process'
diffLib = require 'jsdifflib'

###
Section: Constants used for file/buffer checking against changes
###
statusIndexNew = 1 << 0
statusIndexDeleted = 1 << 2

statusWorkingDirNew = 1 << 7
statusWorkingDirModified = 1 << 8
statusWorkingDirDelete = 1 << 9
statusWorkingDirTypeChange = 1 << 10
statusIgnored = 1 << 14

modifiedStatusFlags = statusWorkingDirModified | statusWorkingDirDelete |
                      statusWorkingDirTypeChange | statusIndexDeleted

newStatusFlags = statusWorkingDirNew | statusIndexNew

deletedStatusFlags = statusWorkingDirDelete | statusIndexDeleted

suppressSvnWarnings = [
  'W200005' # svn: warning: W200005: 'file' is not under version control
  'E200009' # Could not cat all targets because some targets are not versioned
]

class Repository

  devMode: atom.inDevMode()

  username: null
  password: null

  rootPath: null

  isSvnRepository: false
  binaryAvailable: false

  version: null

  url: null
  urlPath: null
  shortHead: null

  revision: null


  ###
  Section: Initialization and startup checks
  ###

  constructor: (repoRootPath) ->
    @rootPath = pathlib.normalize(repoRootPath)
    console.log('SVN', 'svn-utils', 'repoRootPath', @rootPath) if @devMode

  # Checks if there is a svn binary in the os searchpath and returns the
  # binary version string.
  #
  # Returns a {boolean}
  checkBinaryAvailable: () ->
    @version = @getSvnVersion()
    if @version?
      console.log('SVN', 'svn-utils', "binary version: #{@version}") if @devMode
      @binaryAvailable = true
    else
      @binaryAvailable = false
    return @binaryAvailable

  # Parses info from `svn info` and `svnversion` command and checks if repo infos have changed
  # since last check
  #
  # Returns a {boolean} if repo infos have changed
  checkRepositoryHasChanged: () ->
    hasChanged = false
    revision = @getSvnWorkingCopyRevision()
    if revision?
      # remove modified, switched and partial infos from revision number
      revision = revision.replace(/[MSP]/gi, '')
      console.log('SVN', 'svn-utils', 'revision', revision) if @devMode
      if revision != @revision
        @revision = revision
        hasChanged = true

    info = @getSvnInfo()
    if info? && info.url?
      console.log('SVN', 'svn-utils', 'url', info.url) if @devMode
      if info.url != @url
        @url = info.url
        urlParts = urlParser.parse(info.url)
        @urlPath = urlParts.path
        pathParts = @urlPath.split('/')
        @shortHead = if pathParts.length > 0 then pathParts.pop() else ''
        hasChanged = true

    return hasChanged

  getShortHead: () ->
    return @shortHead

  ###
  Section: TreeView Path SVN status
  ###

  # Parses `svn status`. Gets initially called by svn-repository.refreshStatus()
  #
  # Returns a {Array} array keys are paths, values are change constants. Or null
  getStatus: () ->
    statuses = @getSvnStatus()
    return statuses

  # Parses `svn status`. Gets called by svn-repository.refreshStatus()
  #
  # Returns an {Array} Array keys are paths, values are change constants
  getPathStatus: (svnPath) ->
    status = @getSvnPathStatus(svnPath)
    return status

  getPath: () ->
    return @rootPath

  isStatusModified: (status=0) ->
    (status & modifiedStatusFlags) > 0

  isPathModified: (path) ->
    @isStatusModified(@getPathStatus(path))

  isStatusNew: (status=0) ->
    (status & newStatusFlags) > 0

  isPathNew: (path) ->
    @isStatusNew(@getPathStatus(path))

  isStatusDeleted: (status=0) ->
    (status & deletedStatusFlags) > 0

  isPathDeleted: (path) ->
    @isStatusDeleted(@getPathStatus(path))

  isPathStaged: (path) ->
    @isStatusStaged(@getPathStatus(path))

  isStatusIgnored: (status=0) ->
    (status & statusIgnored) > 0

  isStatusStaged: (status=0) ->
    (status & indexStatusFlags) > 0


  ###
  Section: Editor SVN line diffs
  ###

  # Public: Retrieves the number of lines added and removed to a path.
  #
  # This compares the working directory contents of the path to the `HEAD`
  # version.
  #
  # * `path` The {String} path to check.
  # * `lastRevFileContent` filecontent from latest svn revision.
  #
  # Returns an {Object} with the following keys:
  #   * `added` The {Number} of added lines.
  #   * `deleted` The {Number} of deleted lines.
  getDiffStats: (path, lastRevFileContent) ->
    diffStats = {
      added: 0
      deleted: 0
    }
    if (lastRevFileContent? && fs.existsSync(path))
      base = diffLib.stringAsLines(lastRevFileContent)
      newtxt = diffLib.stringAsLines(fs.readFileSync(path).toString())

      # create a SequenceMatcher instance that diffs the two sets of lines
      sm = new diffLib.SequenceMatcher(base, newtxt)

      # get the opcodes from the SequenceMatcher instance
      # opcodes is a list of 3-tuples describing what changes should be made to the base text
      # in order to yield the new text
      opcodes = sm.get_opcodes()

      for opcode in opcodes
        if opcode[0] == 'insert' || opcode[0] == 'replace'
          diffStats.added += (opcode[2] - opcode[1]) + (opcode[4] - opcode[3])
        if opcode[0] == 'delete'
          diffStats.deleted += (opcode[2] - opcode[1]) - (opcode[4] - opcode[3])

    console.log('SVN', 'svn-utils', 'getDiffStats', path, diffStats) if @devMode
    return diffStats

  # Public: Retrieves the line diffs comparing the `HEAD` version of the given
  # path and the given text.
  #
  # * `lastRevFileContent` filecontent from latest svn revision.
  # * `text` The {String} to compare against the `HEAD` contents
  #
  # Returns an {Array} of hunk {Object}s with the following keys:
  #   * `oldStart` The line {Number} of the old hunk.
  #   * `newStart` The line {Number} of the new hunk.
  #   * `oldLines` The {Number} of lines in the old hunk.
  #   * `newLines` The {Number} of lines in the new hunk
  getLineDiffs: (lastRevFileContent, text, options) ->
    console.log('SVN', 'svn-utils', 'getLineDiffs', options) if @devMode
    hunks = []

    if (lastRevFileContent?)
      base = diffLib.stringAsLines(lastRevFileContent)
      newtxt = diffLib.stringAsLines(text)
      # create a SequenceMatcher instance that diffs the two sets of lines
      sm = new diffLib.SequenceMatcher(base, newtxt)

      # get the opcodes from the SequenceMatcher instance
      # opcodes is a list of 3-tuples describing what changes should be made to the base text
      # in order to yield the new text
      opcodes = sm.get_opcodes()

      actions = ['replace', 'insert', 'delete']
      for opcode in opcodes
        if actions.indexOf(opcode[0]) >= 0
          hunk = {
            oldStart: opcode[1] + 1
            oldLines: opcode[2] - opcode[1]
            newStart: opcode[3] + 1
            newLines: opcode[4] - opcode[3]
          }
          if opcode[0] == 'delete'
            hunk.newStart = hunk.newStart - 1
          hunks.push(hunk)

    return hunks

  ###
  Section: SVN Command handling
  ###

  # Spawns an svn command and returns stdout or throws an error if process
  # exits with an exitcode unequal to zero.
  #
  # * `params` The {Array} for commandline arguments
  #
  # Returns a {String} of process stdout
  svnCommand: (params) ->
    if !params
      params = []
    if !util.isArray(params)
      params = [params]
    child = spawnSync('svn', params)
    if child.status != 0
      throw new Error(child.stderr.toString())
    return child.stdout.toString()

  # Spawns an svnversion command and returns stdout or throws an error if process
  # exits with an exitcode unequal to zero.
  #
  # * `params` The {Array} for commandline arguments
  #
  # Returns a {String} of process stdout
  svnversionCommand: (params) ->
    if !params
      params = []
    if !util.isArray(params)
      params = [params]
    child = spawnSync('svnversion', params)
    if child.status != 0
      throw new Error(child.stderr.toString())
    return child.stdout.toString()

  handleSvnError: (error) ->
    logMessage = true
    message = error.message
    for suppressSvnWarning in suppressSvnWarnings
      if message.indexOf(suppressSvnWarning) > 0
        logMessage = false
        break
    if logMessage
      console.error('SVN', 'svn-utils', error)

  # Returns on success the version from the svn binary. Otherwise null.
  #
  # Returns a {String} containing the svn-binary version
  getSvnVersion: () ->
    try
      version = @svnCommand(['--version', '--quiet'])
      return version.trim()
    catch error
      @handleSvnError(error)
      return null

  # Returns on success an svn-info object. Otherwise null.
  #
  # Returns a {Object} with data from `svn info` command
  getSvnInfo: () ->
    try
      xml = @svnCommand(['info', '--xml', @rootPath])
      xmlDocument = $.parseXML(xml)
      return {
        url: $('info > entry > url', xmlDocument).text()
      }
    catch error
      @handleSvnError(error)
      return null

  # Returns on success the current working copy revision. Otherwise null.
  #
  # Returns a {String} with the current working copy revision
  getSvnWorkingCopyRevision: () ->
    try
      revisions = @svnversionCommand([@rootPath, '-n'])
      return revisions.split(':')[1]
    catch error
      @handleSvnError(error)
      return null

  # Returns on success an svn-ignores array. Otherwise null.
  # Array keys are paths, values {Number} representing the status
  #
  # Returns a {Array} with path and statusnumber
  getRecursiveIgnoreStatuses: () ->
    try
      xml = @svnCommand(['propget', '-R', '--xml', 'svn:ignore', @rootPath])
      xmlDocument = $.parseXML(xml)
    catch error
      @handleSvnError(error)
      return null

    items = []
    targets = $('properties > target', xmlDocument)
    if targets
      for target in targets
        basePath = $(target).attr('path')
        ignores = $('property', target).text()
        if ignores
          ignoredItems = ignores.split('\n')
          for ignoredItem in ignoredItems
            if (ignoredItem and ignoredItem.length > 0)
              items.push(basePath + '/' + ignoredItem)

    return items

  # Returns on success an svn-status array. Otherwise null.
  # Array keys are paths, values {Number} representing the status
  #
  # Returns a {Array} with path and statusnumber
  getSvnStatus: () ->
    try
      xml = @svnCommand(['status', '-q','--xml', @rootPath])
      xmlDocument = $.parseXML(xml)
    catch error
      @handleSvnError(error)
      return null

    items = []
    entries = $('status > target > entry', xmlDocument)
    if entries
      for entry in entries
        path = $(entry).attr('path')
        status = $('wc-status', entry).attr('item')
        if path? && status?
          items.push({
            'path': path
            'status': @mapSvnStatus(status)
          })

    return items

  # Returns on success a status bitmask. Otherwise null.
  #
  # * `svnPath` The path {String} for the status inquiry
  #
  # Returns a {Number} representing the status
  getSvnPathStatus: (svnPath) ->
    return null unless svnPath

    try
      xml = @svnCommand(['status', '-q','--xml', svnPath])
      xmlDocument = $.parseXML(xml)
    catch error
      @handleSvnError(error)
      return null

    status = 0
    entries = $('status > target > entry', xmlDocument)
    if entries
      for entry in entries
        entryStatus = $('wc-status', entry).attr('item')
        if entryStatus?
          status |= @mapSvnStatus(entryStatus)
      return status
    else
      return null

  # Translates the status {String} from `svn status` command into a
  # status {Number}.
  #
  # * `status` The status {String} from `svn status` command
  #
  # Returns a {Number} representing the status
  mapSvnStatus: (status) ->
    return 0 unless status
    statusBitmask = 0

    # status workingdir
    if status == 'modified'
      statusBitmask = statusWorkingDirModified
    if status == 'unversioned'
      statusBitmask = statusWorkingDirNew
    if status == 'missing'
      statusBitmask = statusWorkingDirDelete
    if status == 'ignored'
      statusBitmask = statusIgnored
    if status == 'normal' && status.props == 'modified'
      statusBitmask = statusWorkingDirTypeChange

    # status index
    if status == 'added'
      statusBitmask = statusIndexNew
    if status == 'deleted'
      statusBitmask = statusIndexDeleted

    return statusBitmask

  # This retrieves the contents of the svnpath from the `HEAD` on success.
  # Otherwise null.
  #
  # * `svnPath` The path {String}
  #
  # Returns the {String} as filecontent
  getSvnCat: (svnPath) ->
    params = [
      'cat'
      svnPath
    ]
    try
      fileContent = @svnCommand(params)
      return fileContent
    catch error
      @handleSvnError(error)
      return null


# creates and returns a new {Repository} object if svn-binary could be found
# and several infos from are successfully read. Otherwise null.
#
# * `repositoryPath` The path {String} to the repository root directory
#
# Returns a new {Repository} object
openRepository = (repositoryPath) ->
  repository = new Repository(repositoryPath)
  if repository.checkBinaryAvailable()
    return repository
  else
    return null


exports.open = (repositoryPath) ->
  return openRepository(repositoryPath)
