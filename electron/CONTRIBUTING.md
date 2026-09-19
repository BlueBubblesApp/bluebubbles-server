# Contribution Guide

We encourage all contributions to this project! All we ask are you follow these simple rules when contributing:

* Write clean code
* Comment your code
* Follow Typescript and React best practices
    - [Typescript Best Practices](https://www.typescriptlang.org/docs/handbook/declaration-files/do-s-and-don-ts.html)
    - [React Best Practices](https://reactjs.org/docs/thinking-in-react.html)

## Pre-requisites

Please make sure you have completed the following pre-requisites:

* Install Git: [download](https://git-scm.com/downloads)
* Install NodeJS (Latest Stable): [download](https://nodejs.org/en/)
* Install a code editor. Here are a few recommended editors:
    - [Visual Studio Code](https://code.visualstudio.com/download)
    - [Android Studio](https://developer.android.com/studio)
    - [Atom](https://atom.io/)

Once you have a code editor installed, remember to install all of the required plugins/extensions such as the following:

* Typescript
* ESLint
* Prettier

## Forking the Repository

In order to start contributing, follow these steps:

1. Create a GitHub account
2. Fork the `BlueBubbles-Server` repository: [here](https://github.com/BlueBubblesApp/BlueBubbles-Server)
3. On your desktop, clone your forked repository:
    * HTTPS: `git clone https://github.com/BlueBubblesApp/BlueBubbles-Server.git`
    * SSH: `git clone git@github.com:BlueBubblesApp/BlueBubbles-Server.git`
4. Set the upstream to our main repo (this will allow you to pull official changes)
    * `git remote add upstream git@github.com:BlueBubblesApp/BlueBubbles-Server.git`
5. Fetch all the required branches/code
    * `git fetch`
    * `git fetch upstream`
6. Pull the latest changes, or a specific branch you want to start from
    * Pull code from the main repository's master branch: `git pull upstream master`
    * Checkout a specific branch: `git checkout upstream <name of branch>`

## Committing Code

1. Make your code changes :)
2. Create your own branch
    * `git checkout -b <your name>/<feature>`
    * Example: `git checkout -b zach/improved-animations`
3. Stage your changes to the commit using a code-editor plugin, or Git directly
    * Stage a specific file: `git add <file name>`
    * Stage all changes: `git add -A`
4. Commit your changes
    * `git commit -m "<Description of your changes>"`
5. Push your changes to your forked repository
    * `git push origin <your branch name>`

## Submitting a Pull-Request

Once you have made all your changes, follow these instructions:

1. Login to GitHub's website
2. Go to your forked `BlueBubbles-Server` repository
3. Go to the `Pull requests` tab
4. Create a new Pull request, merging your changes into the main `development` branch
5. Please include the following information with your pull request:
    * The problem
    * What your code solves
    * How you fixed it
6. Once submitted, your changes will be reviewed, and hopefully committed into the master branch!
