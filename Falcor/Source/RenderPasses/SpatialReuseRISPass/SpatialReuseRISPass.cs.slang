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

#include "Utils/Math/MathConstants.slangh"

import Utils.Math.MathHelpers;
import Utils.Sampling.SampleGenerator;

RWTexture2D<float4> gPosW;
RWTexture2D<float4> gNormW;
RWTexture2D<float4> gEmittedLight; // xyz: incoming radiance (y)
RWTexture2D<float4> gDirToSample;  // xyz: direction to light sample, w: distance to the light sample
RWTexture2D<float4> gSampleNormalArea; // xyz: sample normal, w: area of the light
RWTexture2D<float4> gReservoir; // x: weight, y: sum of weights, z: number of candidates M, w: frame number
RWTexture2D<float4> gDiff; // xyz: sample diffuse BRDF


RWTexture2D<float4> gReservoirOut;
RWTexture2D<float4> gEmittedLightOut;
RWTexture2D<float4> gDirToSampleOut;
RWTexture2D<float4> gSampleNormalAreaOut;

cbuffer CB {
	uint width;
	uint height;
	uint frameCount;
}

void updateReservoir(float3 Li, float4 dirToSample, float w, uint2 pixel, inout SampleGenerator sg, inout bool updated)
{
	gReservoirOut[pixel].y += w;
	gReservoirOut[pixel].z += 1.0f;
	if(gReservoirOut[pixel].y > 0.0f && sampleNext1D(sg) < (w / gReservoirOut[pixel].y))
	{
		updated = true;
		gEmittedLightOut[pixel] = float4(Li, 1.f);
		gDirToSampleOut[pixel] = dirToSample;
	}
	return;
}


float evalTargetPDF(float3 diff, float3 Li, float3 lightDir, float3 surfNormal)
{
	float G = max(dot(lightDir, surfNormal), 0.0f);
	return length(diff * Li * G);
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId : SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
	
    SampleGenerator sg = SampleGenerator(pixel, frameCount);
	int M_sum = 0;
	
	gReservoirOut[pixel] = gReservoir[pixel];
	gEmittedLightOut[pixel] = gEmittedLight[pixel];
	gDirToSampleOut[pixel] = gDirToSample[pixel];
	gSampleNormalAreaOut[pixel] = gSampleNormalArea[pixel];
	
	if(gPosW[pixel].w == 0.0f) 
	{
		return;
	}
	
	bool updated = false;

	[unroll]
	for(int i = 0; i < 5; i++)
	{
    
		float r = 15.0f * sqrt(sampleNext1D(sg));
		float theta = 2.0f * M_PI * sampleNext1D(sg);
		float2 randomPixel = pixel;
		randomPixel.x += r * cos(theta);
		randomPixel.y += r * sin(theta);
		
		// Discard pixel if out of bounds
		if(randomPixel.x < 0 || randomPixel.x >= width || randomPixel.y < 0 || randomPixel.y >= height)
		{
			continue;
		}
		
		uint2 neighborPixel = (uint2)randomPixel;

        // Skip the reservoir if the weight is 0
		if (gReservoir[neighborPixel].x == 0) 
		{
			M_sum += (int)gReservoir[neighborPixel].z;
			continue;
		}
		
		// Normal degree test - 25° angle threshold
		if(dot(gNormW[pixel].xyz, gNormW[neighborPixel].xyz) < 0.906312f) 
		{
			continue;
		}
		
		// Depth test - 10% of depth threshold
		if (gNormW[neighborPixel].w > 1.1f * gNormW[pixel].w || gNormW[neighborPixel].w < 0.9f * gNormW[pixel].w) 
		{
			continue;
		}

		float3 lightPosW = gDirToSample[neighborPixel].xyz * gDirToSample[neighborPixel].w + gPosW[neighborPixel].xyz;
		float4 newDirToSample = float4(normalize(lightPosW - gPosW[pixel].xyz), length(lightPosW - gPosW[pixel].xyz));
		
		float targetPDF = evalTargetPDF(gDiff[pixel].xyz, gEmittedLight[neighborPixel].xyz, newDirToSample.xyz, gNormW[pixel].xyz);

		float w = targetPDF * gReservoir[neighborPixel].x * gReservoir[neighborPixel].z;
		
		updateReservoir(gEmittedLight[neighborPixel].xyz, newDirToSample, w, pixel, sg, updated);
		
		M_sum += (int)gReservoir[neighborPixel].z;
		
	}
	
	gReservoirOut[pixel].z += (float)M_sum;
	
	if(!updated) return;
	
	float targetPDF = evalTargetPDF(gDiff[pixel].xyz, gEmittedLightOut[pixel].xyz, gDirToSampleOut[pixel].xyz, gNormW[pixel].xyz);
	
	if(gReservoirOut[pixel].z == 0 || targetPDF == 0) 
	{
		gReservoirOut[pixel].x = 0.0f;
	}
	else 
	{
		gReservoirOut[pixel].x = gReservoirOut[pixel].y / (gReservoirOut[pixel].z * targetPDF);
	}
	
}
