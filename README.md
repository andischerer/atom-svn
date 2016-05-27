# SVN package

SVN VCS integration: Marks lines/files in the editor gutter/treeview that have been added, edited, or deleted since the last commit. Repository status information get displayed in footer.

The `git-diff` package has to be enabled to see the repository status marks in gutter and treeview.

This package uses a __binary svn wrapper__. So you have to put your svn-binary in your os __searchpath__.

This package plays well with third party plugins(like minimap-git-diff) who consume the `repository-provider` service.

## Installation ##
### From atom GUI
Go in Atom's **Settings** page, through **packages** section. Under **Community Packages** search for "*svn*" and Install it.

### From commandline
Open commandline and install this package by executing the following command:
```
apm install svn
```


# Team
[![Andreas Scherer](https://avatars.githubusercontent.com/u/930604?s=130)](https://github.com/andischerer) | [![Orvar Segerström](https://avatars.githubusercontent.com/u/1098408?s=130)](https://github.com/awestroke)
---|---|---|---
[Andreas Scherer](https://github.com/andischerer) | [Orvar Segerström](https://github.com/awestroke)