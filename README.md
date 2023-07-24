# zig-zag-zoe
Multiplayer TicTacToe - in Zig - using HTMX for that zero-javascript experience

Online demo here
http://zig-zag-zoe.com

.. (running on a t4g-nano instance on AWS - Linux ARM64, with 512MB memory )

** Uses Zig Master  0.11-dev **

![screenshot](https://github.com/zigster64/zig-zag-zoe/blob/main/src/images/zzz-screenshot.jpg)

# Install

```
git clone https://github.com/zigster64/zig-zag-zoe.git
cd zig-zag-zoe
zig build
```

# Build and Run

```
zig build

.. or

zig build run
```

Now point your browsers at http://localhost:3000

.. or the equivalent address on the local network


# GamePlay

- Set us up a new game
- Choose the number of rows and columns for the grid.
- Choose the number of players.
- Choose the number of squares needed to win.
- Choose a % chance of a Zero Wing.
- Chosse a % chance to set us up the bomb.
- Click START
- At this point, the system will wait for all players to login - which is done by simply selecting which player to play as.
- Once logged in, you will see (in real time) who we are waiting on, and watch as they all login.
- Once everyone has logged in, the board is presented, and the game begins !
- Main screen on. Make your move ZIG !
- Keep playing until someone set us up the win

## The Clock / Timer

Each phase has a clock timer - usually 30 seconds, which counts down to 0.

Each time a player completes their turn, the clock is reset.

If the clock ever gets down to 0, the game is terminated, and everyone loses.

The reason for this is to allow the game to run on a public server, and not get stuck in some mode where its waiting for a player to do something, and everyone runs, freezing the game forever in that waiting state.

## Winning the Game

Each player takes a turn, selecting an empty square to place their piece in. 

IF a player gets X in a row (where X == the number of squares needed to win), then they win, and everyone else loses !

## Zero Wing Enabled

Each turn, a player may randomly get Zero Wing Enabled. In this mode, the border of the board is printed in orange, and they can click on ANY square 
(including both empty squares AND squares that has another players piece already), and it is changed to their piece.

## Set us up the Bomb

Each turn, a player may randomly get "Someone set us up the bomb". In this mode, the border of the board is printed in red,
and when they click on an EMPTY square, then their piece is placed in that square AND all adjacent squares are emptied out.

Be careful where you click, because you just might wipe out your own pieces.

## Bugs

There is a bug where sometimes in normal mode ... usually after the previous player had bomb mode ... then clicking on a square
seems to zap 1 other adjacent square.  Maybe. Cant reproduce it yet.

I will either fix this bug, or leave it in there as a feature - rationale is that there might be some bomb residue laying around
after someone set us up the bomb.


# Whats Interesting

This code is interesting for the following reasons :

- Its all written in Zig
- It uses the excellent http.zig library https://github.com/karlseguin/http.zig
- Generated docker image = about 300kb
- Run stats - uses about 60MB RAM and really low CPU %
- Its about as simple as doing the same thing in Go, there is really nothing too nasty required in the code.  
- The router, and all the HTML contents is part of the Game object ... the implications of this are that it is possible to create 'web components' using this
zig/htmx approach that are all self contained, and can be imported into other projects, without having to know about connecting up routes, or pulling in content. Interesting.
- Uses SSE / Event Streams to keep it all realtime updates with pub/sub from multiple players. Is simple, and it works.
- Demonstrates how to do threading, thread conditions / signalling, and using mutexes to make object updates thread safe.
- No websockets needed
- There is pretty much NO JAVASCRIPT on the frontend. It uses HTMX https://htmx.org ... which is an alternative approach to web clients, where the frontend is pure hypertext, and everything is done on the backend
- There is a tiny bit of JS, to update the session ID, but im still thinking up a way of getting rid of that as well.
- Uses std.fmt.print() as the templating engine.  I didnt know before, but you can use named tags inside the comptime format string, and use those to reference fields in the args param. 
Actually makes for a half decent templating tool, without having to find and import a templating lib.


## HTMX thoughts

Yeah, its pretty cool, worth adding to your toolbelt. Not sure its really a 'replacement' for SPA type apps - I think it might be painful for larger apps. Not sure, havnt tried yet.

What it is 100% excellent for though is for doing apps where there is a lot of shared state between users. (Like a turn based game !) In that case, doing everything on the server, and not having any state
at all on the frontend to sync, is really ideal.  Its a good fit to this sort of problem.

Its super robust. You can do horrible things like reboot the backend, or hard refresh the front end(s) ... and it maintains state without a hiccup, and without needing any exception handling code at all. 
Very nice. It would be a nightmare doing this in react.

There are some very complex things you could do with a turn-based-multiplayer-game type of model though (doesnt have to be a game even) And being able to do that without touching JS, or
writing a tonne of code to synch state on the frontends is really nice.

Its also a reasonable model for doing shared state between GUI frontends, just using the HTTP/SSE protocol too. Its just HTTP requests, so the networking is totally portable.
