# Things to do
- RL AI implementation
- Menu improvement, more similar to the civ VI menu
- Multiplayer
 
# Ideas

# Bugs
- Shadow of home/house is a bit lower. I think we should recheck all building shadows. Also shadows of units jumping is not excellent.
- We need to stress test defense of towns, I have seen attacking indenpendent towns that they don't defend it completly. The attacking units are in the area of the town and even atacking the townhall and the I don't know if get stuck on the back of the townhall or not even detect him. Because I have seen that they are even idle most of the time.

# Corrections

# Things to check
- Easy to see what kingdom is from the town defended or attacked in the townhall options and by arrows color when town selected

# Clarifications and reminders
- With 2 slices, AI decisions happen every 0.5 s and rendering lags the simulation by up to one slice window. If that feels sluggish, changing UNIT_UPDATE_SLICES is the single knob; 1 restores old responsiveness, 3+ scales further.
