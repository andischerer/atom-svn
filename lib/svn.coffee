SvnRepositoryProvider = require './svn-repository-provider'

module.exports =
  activate: -> null

  deactivate: -> null

  getRepositoryProviderService: ->
    new SvnRepositoryProvider(atom.project)
