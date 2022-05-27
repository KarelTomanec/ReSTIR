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
#include "TemporalReuseRISPass.h"

const RenderPass::Info TemporalReuseRISPass::kInfo { "TemporalReuseRISPass", "Insert pass description here." };

namespace
{

    const char kShaderFile[] = "RenderPasses/TemporalReuseRISPass/TemporalReuseRISPass.cs.slang";
    const std::string kShaderModel = "6_5";

    const ChannelList kInputChannels =
    {
        { "posW",                       "gPosW",                        "World space position",                                 true /* optional */, ResourceFormat::RGBA32Float   },
        { "normW",                      "gNormW",                       "World space normal",                                   true /* optional */, ResourceFormat::RGBA32Float   },
        { "emittedLight",               "gEmittedLight",                "Emitted light from the selected light source sample",  true /* optional */, ResourceFormat::RGBA32Float   },
        { "dirToSample",                "gDirToSample",                 "Direction to the selected light source sample",        true /* optional */, ResourceFormat::RGBA32Float   },
        { "reservoir",                  "gReservoir",                   "Number of candidates and reservoir weights",           true /* optional */, ResourceFormat::RGBA32Float   },
        { "diff",                       "gDiff",                        "Diffuse BRDF",                                         true /* optional */, ResourceFormat::RGBA32Float       },
        { "mvec",                       "gMotionVector",                "Screen space motion vectors",                          true /* optional */, ResourceFormat::RG32Float       },

    };

    const ChannelList kOutputChannels =
    {
        { "emittedLight",               "gEmittedLight",                "Emitted light from the selected light source sample",  true /* optional */, ResourceFormat::RGBA32Float   },
        { "dirToSample",                "gDirToSample",                 "Direction to the selected light source sample",        true /* optional */, ResourceFormat::RGBA32Float   },
        { "reservoir",                  "gReservoir",                   "Number of candidates and reservoir weights",                                      true /* optional */, ResourceFormat::RGBA32Float   },
    };


    const std::string kNormalPrev = "normalPrev";
}

// Don't remove this. it's required for hot-reload to function properly
extern "C" FALCOR_API_EXPORT const char* getProjDir()
{
    return PROJECT_DIR;
}

extern "C" FALCOR_API_EXPORT void getPasses(Falcor::RenderPassLibrary& lib)
{
    lib.registerPass(TemporalReuseRISPass::kInfo, TemporalReuseRISPass::create);
}

TemporalReuseRISPass::TemporalReuseRISPass() : RenderPass(kInfo)
{
    // Create random engine
    mpSampleGenerator = SampleGenerator::create(SAMPLE_GENERATOR_DEFAULT);
    FALCOR_ASSERT(mpSampleGenerator);
}

TemporalReuseRISPass::SharedPtr TemporalReuseRISPass::create(RenderContext* pRenderContext, const Dictionary& dict)
{
    SharedPtr pPass = SharedPtr(new TemporalReuseRISPass());
    return pPass;
}

Dictionary TemporalReuseRISPass::getScriptingDictionary()
{
    return Dictionary();
}

RenderPassReflection TemporalReuseRISPass::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;

    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels);
    reflector.addInternal(kNormalPrev, "todo: description");

    return reflector;
}


void TemporalReuseRISPass::reset()
{
    mFrameCount = 0;
}


void TemporalReuseRISPass::prepareInternalChannels(RenderContext* pRenderContext, uint32_t width, uint32_t height)
{
    // Allocate/resize/clear buffers for intermedate data. These are different depending on accumulation mode.
    // Buffers that are not used in the current mode are released.
    auto prepareBuffer = [&](Texture::SharedPtr& pBuf, ResourceFormat format, bool bufUsed)
    {
        if (!bufUsed)
        {
            pBuf = nullptr;
            return;
        }
        // (Re-)create buffer if needed.
        if (!pBuf || pBuf->getWidth() != width || pBuf->getHeight() != height)
        {
            pBuf = Texture::create2D(width, height, format, 1, 1, nullptr, Resource::BindFlags::ShaderResource | Resource::BindFlags::UnorderedAccess);
            FALCOR_ASSERT(pBuf);
            reset();
        }
        // Clear data if accumulation has been reset (either above or somewhere else).
        if (mFrameCount == 0)
        {
            if (getFormatType(format) == FormatType::Float) pRenderContext->clearUAV(pBuf->getUAV().get(), float4(0.f));
            else pRenderContext->clearUAV(pBuf->getUAV().get(), uint4(0));
        }
    };

    prepareBuffer(mpPosWPrev, ResourceFormat::RGBA32Float, true);
    prepareBuffer(mpNormWPrev, ResourceFormat::RGBA32Float, true);
    prepareBuffer(mpEmittedLightPrev, ResourceFormat::RGBA32Float, true);
    prepareBuffer(mpDirToSamplePrev, ResourceFormat::RGBA32Float, true);
    prepareBuffer(mpDirToSamplePrev, ResourceFormat::RGBA32Float, true);
    prepareBuffer(mpReservoirPrev, ResourceFormat::RGBA32Float, true);

}

void TemporalReuseRISPass::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    // renderData holds the requested resources
    // auto& pTexture = renderData["src"]->asTexture();

    if (!mpTemporalReuseRISPass)
    {
        Program::Desc desc;
        desc.addShaderLibrary(kShaderFile).setShaderModel(kShaderModel).csEntry("main");

        Program::DefineList defines;
        defines.add(mpSampleGenerator->getDefines());


        mpTemporalReuseRISPass = ComputePass::create(desc, defines);
    }

    // Bind output channels as UAV buffers.
    auto var = mpTemporalReuseRISPass->getRootVar();
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



    // Setup internals
    prepareInternalChannels(pRenderContext, mFrameDim.x, mFrameDim.y);

    //mpTemporalReuseRISPass["gPosWPrev"] = mpPosWPrev;
    //mpTemporalReuseRISPass["gNormWPrev"] = mpNormWPrev;
    //mpTemporalReuseRISPass["gEmittedLightPrev"] = mpEmittedLightPrev;
    //mpTemporalReuseRISPass["gDirToSamplePrev"] = mpDirToSamplePrev;
    //mpTemporalReuseRISPass["gSampleNormalAreaPrev"] = mpSampleNormalAreaPrev;
    //mpTemporalReuseRISPass["gReservoirPrev"] = mpReservoirPrev;

    mpTemporalReuseRISPass->execute(pRenderContext, mFrameDim.x, mFrameDim.y);

    mFrameCount++;
}

void TemporalReuseRISPass::compile(RenderContext* pRenderContext, const CompileData& compileData)
{
    mFrameDim = compileData.defaultTexDims;
}


void TemporalReuseRISPass::renderUI(Gui::Widgets& widget)
{
}
