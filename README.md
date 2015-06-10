# SVN package

SVN VCS integration: Marks lines/files in the editor gutter/treeview that have been added, edited, or deleted since the last commit. Repository status information get displayed in footer.

The `git-diff` package has to be enabled to see the repository status marks in gutter and treeview.

This package uses a __binary svn wrapper__. So you have to put your svn-binary in your os __searchpath__.

This package plays well with third party plugins(like minimap-git-diff) who consume the `repository-provider` service.

__Beware: This package is in early development state__
