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
#include "ShadeRISPass.h"

const RenderPass::Info ShadeRISPass::kInfo{ "ShadeRISPass", "Insert pass description here." };

namespace
{

    const char kShaderFile[] = "RenderPasses/ShadeRISPass/ShadeRISPass.ps.slang";

    const std::string kColorOut = "colorOut";

    const ChannelList kInputChannels =
    {
        { "posW",                       "gPosW",                        "World space position",                                 true /* optional */, ResourceFormat::RGBA32Float   },
        { "normW",                      "gNormW",                       "World space normal",                                   true /* optional */, ResourceFormat::RGBA32Float   },
        { "emittedLight",               "gEmittedLight",                "Emitted light from the selected light source sample",  true /* optional */, ResourceFormat::RGBA32Float   },
        { "dirToSample",                "gDirToSample",                 "Direction to the selected light source sample",        true /* optional */, ResourceFormat::RGBA32Float   },
        { "reservoir",                  "gReservoir",                   "Number of candidates and reservoir weights",           true /* optional */, ResourceFormat::RGBA32Float   },
        { "diff",                       "gDiff",                        "Diffuse BRDF",                                         true /* optional */, ResourceFormat::RGBA32Float   },

    };

    const ChannelList kOutputChannels =
    {
        { "output",                  "gOutput",                          "Output RGBA Color",                                   true /* optional */, ResourceFormat::RGBA32Float  },
    };
}

// Don't remove this. it's required for hot-reload to function properly
extern "C" FALCOR_API_EXPORT const char* getProjDir()
{
    return PROJECT_DIR;
}

extern "C" FALCOR_API_EXPORT void getPasses(Falcor::RenderPassLibrary & lib)
{
    lib.registerPass(ShadeRISPass::kInfo, ShadeRISPass::create);
}

ShadeRISPass::ShadeRISPass() : RenderPass(kInfo)
{
    mComposeData.pRISPass = FullScreenPass::create(kShaderFile);
    //mComposeData.pFbo = Fbo::create();
    Fbo::Desc fboDesc;
    fboDesc.setColorTarget(0, Falcor::ResourceFormat::RGBA32Float);
    mComposeData.pFbo = Fbo::create2D(mFixedOutputSize.x, mFixedOutputSize.y, fboDesc);
}

ShadeRISPass::SharedPtr ShadeRISPass::create(RenderContext* pRenderContext, const Dictionary& dict)
{
    SharedPtr pPass = SharedPtr(new ShadeRISPass());
    return pPass;
}

Dictionary ShadeRISPass::getScriptingDictionary()
{
    return Dictionary();
}

RenderPassReflection ShadeRISPass::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;

    addRenderPassInputs(reflector, kInputChannels);
    //addRenderPassOutputs(reflector, kOutputChannels);
    reflector.addOutput(kColorOut, "Output color");

    return reflector;
}


void ShadeRISPass::compile(RenderContext* pRenderContext, const CompileData& compileData)
{

}


void ShadeRISPass::execute(RenderContext* pRenderContext, const RenderData& renderData)
{

    //auto pPosW = renderData[kPosW];
    //auto pNormW = renderData[kNormW]->asTexture();
    //auto pEmittedLight = renderData[kEmittedLight]->asTexture();
    //auto pDirToSample = renderData[kDirToSample]->asTexture();
    //auto pSampleNormalArea = renderData[kSampleNormalArea]->asTexture();
    //auto pReservoir = renderData[kReservoir]->asTexture();
    //auto pCandidates = renderData[kCandidates]->asTexture();



    //mComposeData.pRISPass["gPosW"] = pPosW;
    //mComposeData.pRISPass["gNormW"] = pNormW;
    //mComposeData.pRISPass["gEmittedLight"] = pEmittedLight;
    //mComposeData.pRISPass["gDirToSample"] = pDirToSample;
    //mComposeData.pRISPass["gSampleNormalArea"] = pSampleNormalArea;
    //mComposeData.pRISPass["gReservoir"] = pReservoir;
    //mComposeData.pRISPass["gCandidates"] = pCandidates;

    //auto pColorOut = renderData[kColorOut]->asTexture();
    //mComposeData.pFbo->attachColorTarget(pColorOut, 0);
    //mComposeData.pRISPass->execute(pRenderContext, mComposeData.pFbo);
    
    // Set constants.
    auto var = mComposeData.pRISPass.getRootVar();
    // Bind I/O buffers. These needs to be done per-frame as the buffers may change anytime.
    auto bind = [&](const ChannelDesc& desc)
    {
        if (!desc.texname.empty())
        {
            var[desc.texname] = renderData[desc.name]->asTexture();
        }
    };
    for (auto channel : kInputChannels) bind(channel);

    auto pColorOut = renderData[kColorOut]->asTexture();
    mComposeData.pFbo->attachColorTarget(pColorOut, 0);
    mComposeData.pRISPass->execute(pRenderContext, mComposeData.pFbo);
}



void ShadeRISPass::renderUI(Gui::Widgets& widget)
{
}
