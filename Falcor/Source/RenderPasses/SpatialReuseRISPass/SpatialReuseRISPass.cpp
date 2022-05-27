/***************************************************************************
 # Copyright (c) 2015-21, NVIDIA CORPORATION. All rights reserved.
 #
 # Redistribution and use in source and binary forms, with or without
 # modification, are permitted provided that the following conditions
 # are met:
 #  * Redistributions of source code must retain the above copyright
 #    notice, this list of conditions and the following disclaimer.
 #  * Redistributions in binary form must reproduce the above copyright
 #    notice, this list of conditions and the following disclaimer in the
 #    documentation and/or other materials provided with the distribution.
 #  * Neither the name of NVIDIA CORPORATION nor the names of its
 #    contributors may be used to endorse or promote products derived
 #    from this software without specific prior written permission.
 #
 # THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS "AS IS" AND ANY
 # EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 # IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 # PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 # CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 # EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 # PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 # PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 # OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 # (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 # OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **************************************************************************/
#include "SpatialReuseRISPass.h"

const RenderPass::Info SpatialReuseRISPass::kInfo { "SpatialReuseRISPass", "Insert pass description here." };

namespace
{

    const char kShaderFile[] = "RenderPasses/SpatialReuseRISPass/SpatialReuseRISPass.cs.slang";
    const std::string kShaderModel = "6_5";

    const ChannelList kInputChannels =
    {
        { "posW",                       "gPosW",                        "World space position",                                 true /* optional */, ResourceFormat::RGBA32Float   },
        { "normW",                      "gNormW",                       "World space normal",                                   true /* optional */, ResourceFormat::RGBA32Float   },
        { "emittedLight",               "gEmittedLight",                "Emitted light from the selected light source sample",  true /* optional */, ResourceFormat::RGBA32Float   },
        { "dirToSample",                "gDirToSample",                 "Direction to the selected light source sample",        true /* optional */, ResourceFormat::RGBA32Float   },
        { "reservoir",                  "gReservoir",                   "Number of candidates and reservoir weights",           true /* optional */, ResourceFormat::RGBA32Float   },
        { "diff",                       "gDiff",                        "diffuse BRDF",                                         true /* optional */, ResourceFormat::RGBA32Float       },

    };

    const ChannelList kOutputChannels =
    {
        { "emittedLightOut",               "gEmittedLightOut",                "Emitted light from the selected light source sample",  true /* optional */, ResourceFormat::RGBA32Float   },
        { "dirToSampleOut",                "gDirToSampleOut",                 "Direction to the selected light source sample",        true /* optional */, ResourceFormat::RGBA32Float   },
        { "reservoirOut",                  "gReservoirOut",                   "Number of candidates and reservoir weights",           true /* optional */, ResourceFormat::RGBA32Float   },
    };
}

// Don't remove this. it's required for hot-reload to function properly
extern "C" FALCOR_API_EXPORT const char* getProjDir()
{
    return PROJECT_DIR;
}

extern "C" FALCOR_API_EXPORT void getPasses(Falcor::RenderPassLibrary& lib)
{
    lib.registerPass(SpatialReuseRISPass::kInfo, SpatialReuseRISPass::create);
}

SpatialReuseRISPass::SpatialReuseRISPass() : RenderPass(kInfo)
{
    // Create random engine
    mpSampleGenerator = SampleGenerator::create(SAMPLE_GENERATOR_DEFAULT);
    FALCOR_ASSERT(mpSampleGenerator);
}

SpatialReuseRISPass::SharedPtr SpatialReuseRISPass::create(RenderContext* pRenderContext, const Dictionary& dict)
{
    SharedPtr pPass = SharedPtr(new SpatialReuseRISPass());
    return pPass;
}

Dictionary SpatialReuseRISPass::getScriptingDictionary()
{
    return Dictionary();
}

RenderPassReflection SpatialReuseRISPass::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;

    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels);

    return reflector;
}

void SpatialReuseRISPass::execute(RenderContext* pRenderContext, const RenderData& renderData)
{

    if (!mpSpatialReuseRISPass)
    {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderFile).setShaderModel(kShaderModel).csEntry("main");

        Program::DefineList defines;
        defines.add(mpSampleGenerator->getDefines());


        mpSpatialReuseRISPass = ComputePass::create(desc, defines, true);
    }

    // Bind output channels as UAV buffers.
    auto var = mpSpatialReuseRISPass->getRootVar();
    auto bind = [&](const ChannelDesc& channel)
    {
        Texture::SharedPtr pTex = renderData[channel.name]->asTexture();
        var[channel.texname] = pTex;
    };
    for (const auto& channel : kOutputChannels) bind(channel);
    for (const auto& channel : kInputChannels) bind(channel);

    var["CB"]["width"] = mFrameDim.x;
    var["CB"]["height"] = mFrameDim.y;
    var["CB"]["frameCount"] = mFrameCount++;

    mpSpatialReuseRISPass->execute(pRenderContext, mFrameDim.x, mFrameDim.y);
}

void SpatialReuseRISPass::compile(RenderContext* pRenderContext, const CompileData& compileData)
{
    mFrameDim = compileData.defaultTexDims;
}


void SpatialReuseRISPass::renderUI(Gui::Widgets& widget)
{
}
