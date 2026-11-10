# **Notes**




## **NEW FEATURE REQUEST**






As of git commit: b92d6ab250fde331c92d08fd4f72d5c6afb8a7b0

I have used --debug twice. One during a 1hr and 3o min lecture and one for a short time with the 1hr and 30min lecture project open

I noticed that after having a lot of text written on the outerbounds of the canvas, there was a noticable delay between transmissions of stroke data.
I wrote a bunch of text in succesion, and it was taking like a second between each transmission.
there is a large amount of delay.

 










FRON PREVIOUS NOTES TAKEN


## **BUGS** 
When I draw off to the edge of the page, and it adds canvas next to the pdf.
So I was writing on that, and I was noticing that erasing was really slow, it would drop the fps down to 0 fps.

In a 1hr 30min lecture, I was noticing serious desync at the 45 min mark. And the manual sync and auto sync takes 
a long time to process. 

A better system might be to have the computer poll the ipad, Ipad says:
"Last Edit was at `TIMESTAMP`, `EDIT NUM`, `PAGE NUM`, `EDIT HASH RELATIVE TO PAGE`"

Then if the computer is behind on timestamp, it would request the latest modifications from `TIMESTAMP` or `HASH`.



Desync is still an issue.

Also, when I change the zoom of the page, the pdf flashes.
 




## **FEATURE REQUESTS**
1. I want to be able to delete pages, and undo page deletes, dont wipe the history when a page is added.


2. I want to be able to customize the look of the extra canvas space. ie:
    - Control the color of the background,
    - color of the grid. 
    - spacing of the grid, (so like square density)
    - option for grid or dot matrix


3. Add a config to change the color of the eraser circle.

 
4. Add a cli flag `--debug=(0,1,2,3)` or smth that will log events. have it default to, or option to write to a file. Add coloring and function traceback and event type.

5. Reduce me min size for the eraser.

