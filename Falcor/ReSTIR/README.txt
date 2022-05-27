To run the ReSTIR algorithm, we need to run Mogwai first.

Building Mogwai
In Visual Studio:

Set your solution configuration to ReleaseD3D12 or DebugD3D12
Right-click on the Mogwai project in the Solution Explorer and select "Set as StartUp Project"
From the top menu bar, select Build -> Build Solution, and wait for compilation to complete
The executable will be Bin/x64/[Debug|Release]/Mogwai.exe

Loading a Scene
Mogwai loads the scene specified by the script, if any. If the script did not load a scene or you 
want to load a different scene, open the load scene dialog by either going to File -> Load Scene 
or hitting Ctrl + Shift + O. Navigate to the location of the scene file you wish to load and select it. 
Alternatively, you can also drag-and-drop scene files into Mogwai.

A sample 'The Modern Living Room' scene is included, which can be found at ReSTIR/pink_room/pink_room.pyscene.

Loading a Script (.py)
Open the load script dialog by either going to File -> Load Script or hitting Ctrl + O. 
Navigate to the location of the script you wish to run and select it to load and run it. 
Alternatively, dragging-and-dropping a script into Mogwai will also work. 
Note that scripts intended for use with Mogwai must be written in Python. Full scripting documentation can be found here.

Here, we'll load the ReSTIR rendering pipeline, located at ReSTIR/ReSTIR.py. (Warning: you need to load the scene first!)

Implementation of individual render passes is located at Source/RenderPasses - GBufferRISPass, VisibilityRISPass, TemporalReuseRISPass, SpatialReuseRISPass, ShadeRISPass.