fs = require 'fs'
path = require 'path'
util = require 'util'
xml2js = require 'xml2js'
{spawnSync} = require('child_process')
diffLib = require('jsdifflib')

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


class Repository

  username: null
  password: null

  rootPath: null

  isSvnRepository: false
  binaryAvailable: false

  version: null
  url: null
  revision: null


  ###
  Section: Initialization and startup checks
  ###

  constructor: (repoRootPath) ->
    @rootPath = path.normalize(repoRootPath)
    console.log 'SVN', 'repoRootPath', @rootPath

  # Checks if there is a svn binary in the os searchpath and returns the
  # binary version string.
  #
  # Returns a {boolean}
  checkBinaryAvailable: () ->
    @version = @getSvnVersion()
    if @version?
      console.log 'SVN', "binary version: #{@version}"
      @binaryAvailable = true
    else
      @binaryAvailable = false
    return @binaryAvailable

  # Parses info from `svn info` command
  #
  # Returns a {boolean} true if no Error was raised, false otherwise
  readRepositoryInfos: () ->
    info = @getSvnInfo()
    if info?
      @url = info.entry.url
      @revision = info.entry.$.revision
      console.log 'SVN', 'url', @url
      console.log 'SVN', 'revision', @revision
      @isSvnRepository = true
    else
      @isSvnRepository = false

    return @isSvnRepository

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

  relativize: (path) ->
    return path unless path
    if process.platform is 'win32'
      path = path.replace(/\\/g, '/')
    else
      return path unless path[0] is '/'

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
  #
  # Returns an {Object} with the following keys:
  #   * `added` The {Number} of added lines.
  #   * `deleted` The {Number} of deleted lines.
  getDiffStats: (path) ->
    diffStats = {
      added: 0
      deleted: 0
    }

    fileFromSvn = @getSvnCat(path)
    if (fileFromSvn? && fs.existsSync(path))
      base = diffLib.stringAsLines(fileFromSvn)
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

    console.log 'SVN', 'getDiffStats', path, diffStats
    return diffStats

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
  getLineDiffs: (path, text, options) ->
    console.log 'SVN', 'getLineDiffs', path, options
    hunks = []

    fileFromSvn = @getSvnCat(path)
    if (fileFromSvn?)
      base = diffLib.stringAsLines(fileFromSvn)
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

  handleSvnError: (error) ->
    console.error(error)

  # Parses the stdout xml string from a svn command and transforms it
  # into a JSON-Object. Throws an Error if there was a parse error.
  #
  # * `xmlResult` The xml {String} form a svn command
  #
  # Returns a {Object} from the xml result
  svnXmlToObject: (xmlResult) ->
    infoObject = null
    xml2js.parseString(xmlResult, {
      async: false
      explicitRoot: false
      explicitArray: false
    }, (err, result) ->
      if (err)
        throw new Error(err)
      infoObject = result
    )
    return infoObject

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
      infoObject = @svnXmlToObject(xml)
      return infoObject
    catch error
      @handleSvnError(error)
      return null

  # Returns on success an svn-status array. Otherwise null.
  # Array keys are paths, values {Number} representing the status
  #
  # Returns a {Array} with path and statusnumber
  getSvnStatus: () ->
    try
      xml = @svnCommand(['status', '-q','--xml', @rootPath])
      result = @svnXmlToObject(xml)
    catch error
      @handleSvnError(error)
      return null

    items = []
    if (result.target.entry)
      resultArray = result.target.entry
      if !util.isArray(resultArray)
        resultArray = [result.target.entry]
      for resultItem in resultArray
        items.push({
          'path': resultItem.$.path
          'status': @mapSvnStatus(resultItem["wc-status"].$)
        })
    else
      items.push({
        'path': svnPath
        'status': 0
      })
    return items

  # Returns on success an svn-status array. Otherwise null.
  # Array keys are paths, values {Number} representing the status
  #
  # * `svnPath` The path {String} for the status inquiry
  #
  # Returns a {Number} representing the status
  getSvnPathStatus: (svnPath) ->
    return null unless svnPath

    try
      xml = @svnCommand(['status', '-q','--xml', svnPath])
      result = @svnXmlToObject(xml)
    catch error
      @handleSvnError(error)
      return null

    status = 0
    result = result.target.entry
    if (result?)

      if util.isArray(result)
        for item in result
          status |= @mapSvnStatus(item["wc-status"].$)
      else
        status = @mapSvnStatus(result["wc-status"].$)

      return status
    else
      return null

  # Translates the status {String} from `svn status` command into a
  # status {Number}.
  #
  # * `status` The status {Object} from `svn status` command
  #
  # Returns a {Number} representing the status
  mapSvnStatus: (status) ->
    statusBitmask = 0

    # status workingdir
    if status.item == 'modified'
      statusBitmask = statusWorkingDirModified
    if status.item == 'unversioned'
      statusBitmask = statusWorkingDirNew
    if status.item == 'missing'
      statusBitmask = statusWorkingDirDelete
    if status.item == 'ignored'
      statusBitmask = statusIgnored
    if status.item == 'normal' && status.props == 'modified'
      statusBitmask = statusWorkingDirTypeChange

    # status index
    if status.item == 'added'
      statusBitmask = statusIndexNew
    if status.item == 'deleted'
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


openRepository = (repositoryPath) ->
  repository = new Repository(repositoryPath)
  if repository.checkBinaryAvailable() && repository.readRepositoryInfos()
    return repository
  else
    return null


exports.open = (repositoryPath) ->
  return openRepository(repositoryPath)
