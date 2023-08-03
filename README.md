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

# How to Play

Please visit teh Wiki / User Manual at

https://github.com/zigster64/zig-zag-zoe/wiki/Zig-Zag-Zoe-%E2%80%90-Zero-Wing-Edition


## Bugs

There is a bug where sometimes in normal mode ... usually after the previous player had bomb mode ... then clicking on a square
seems to zap 1 other adjacent square.  Maybe. Cant reproduce it yet.

I will either fix this bug, or leave it in there as a feature - rationale is that there might be some bomb residue laying around
after someone set us up the bomb.

Havent seen it happen lately, but then I havent changed anything to fix it either .... so who knows ?

## More Modes and Gameplay ideas

Thinking up some new random modes to add to make the game harder - ideas most welcome.

- Poison square ... make the grid square permanently unusable
- Skip ... skip the next player's turn, they miss out
- Reverso ... like uno reverso, reverses the order in which players take turns
- Team Play ... allow multiple users to collab as a team
- Exotic Victory Conditions ... Not just lines, but other shapes to allow victory


# Whats Interesting, from a Code point of view ?

This code is interesting, and worth a read for the following reasons :

- Its all written in Zig. http://ziglang.org.  Fast / Safe / Easy to read  - pick all 3
- It uses the excellent http.zig library https://github.com/karlseguin/http.zig to do all the web stuff. I have had exactly zero issues using this lib.
- Single file binary, which includes the game, a web server, all assets such as HTML, images and audio.  1 file - no litter on your filesystem
- Generated docker image = 770Kb (compressed) All it has is the compiled executable (2.5MB), which includes only a single binary, nothing else.
- Run stats - in ReleaseFast mode running a 2 player game, uses less than 2MB RAM to run, and hardly any CPU. Its pretty resource efficient.
- Its about as simple as doing the same thing in Go, there is really nothing too nasty required in the code.  
- The router, and all the HTML contents is part of the Game object ... the implications of this are that it is possible to create 'web components' using this
zig/htmx approach that are all self contained, and can be imported into other projects, without having to know about connecting up routes, or pulling in content. Interesting.
- Uses SSE / Event Streams to keep it all realtime with pub/sub updates for multiple players. Is simple, and it works, and requires only a trivial amount of code to do.
- Demonstrates how to do threading, thread conditions / signalling, and using mutexes to make object updates thread safe. Its a bit tricky to do cleanly still, but I guess that concurrency was never meant to be easy. Its certainly no harder than doing the some concurrency in Go
- No websockets needed
- There is pretty much NO JAVASCRIPT on the frontend. It uses HTMX https://htmx.org ... which is an alternative approach to web clients, where the frontend is pure hypertext, and everything is done on the backend
- There is a tiny bit of JS, to play some audio, and to update the session ID, but im still thinking up a way of getting rid of that as well.
- Uses std.fmt.print() as the templating engine.  I didnt know before, but you can use named tags inside the comptime format string, and use those to reference fields in the args param. 


Actually makes for a half decent templating tool, without having to find and import a templating lib.

ie
```
response.print("I can use {[name]s} and {[address]s} in a fmt.print statement, and it references fields from the struct passed ", .{
  .name = "Johnny Ziggy",
  .address = "22 Zig Street, Zigville, 90210"
});
```

Thats pretty good - dont really need a templating engine to do most things like that then, can just use std.fmt.print.

In fact, this is better than using a template engine, because you can store the HTML in actual `.html` files ... which means your editor goes into full HTML mode!

Otherwise, need to come up with yet another JSX like thing, and then write a bunch of editor tooling to understand it.  Yuk !

Keep it simple I reckon, just use std.fmt, and just use `.html` files.


Not sure if its worth adding a templating lib - at least to do loops and some basic flow control, because its often much much better to take the full power of a real language instead, and just emit formatted fragments.

Go has a pretty comprehensive and well done Text Templating tool in the stdlib, but its quite a pain to use and impossible to debug when thing do go wrong, compared to doing the hard stuff in a real language.


## HTMX thoughts

Yeah, its pretty cool, worth adding to your toolbelt. Not sure its really a 'replacement' for SPA type apps - I think it might be painful for larger apps. Not sure, havnt tried yet.

What it is 100% excellent for though is for doing apps where there is a lot of shared state between users. (Like a turn based game !) In that case, doing everything on the server, and not having any state
at all on the frontend to sync, is really ideal.  Its a good fit to this sort of problem.

Its super robust. You can do horrible things like reboot the backend, or hard refresh the front end(s) ... and it maintains state without a hiccup, and without needing any exception handling code at all. 
Very nice. It would be a nightmare doing this in react.

There are some very complex things you could do with a turn-based-multiplayer-game type of model though (doesnt have to be a game even) And being able to do that without touching JS, or
writing a tonne of code to synch state on the frontends is really nice.

Its also a reasonable model for doing shared state between GUI frontends, just using the HTTP/SSE protocol too. Its just HTTP requests, so the networking is totally portable.
