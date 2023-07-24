# zig-zag-zoe
Multiplayer TicTacToe - in Zig - using HTMX for that zero-javascript experience

Online demo here
http://zig-zag-zoe.com

.. running on a t4gnano instance on AWS (Linux ARM64, with 512MB memory )

** Uses Zig Master  0.11-dev **

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

Choose the number of rows and columns for the grid.

Choose the number of players.

Choose the number of squares needed to win.

Choose a % chance of a Zero Wing.

Chosse a % chance to set us up the bomb.

Click START

At this point, the system will wait for all players to login - which is done by simply selecting which player to play as.

Once logged in, you will see (in real time) who we are waiting on, and watch as they all login.

Once everyone has logged in, the board is presented, and the game begins !

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
