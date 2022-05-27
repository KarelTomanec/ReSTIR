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

RWTexture2D<float4> gPosW; // xyz: world space position
RWTexture2D<float4> gNormW; // xyz: world space normal vector, w: depth
RWTexture2D<float4> gEmittedLight; // xyz: incoming radiance (y)
RWTexture2D<float4> gDirToSample;  // xyz: direction to light sample, w: distance to the light sample
RWTexture2D<float4> gSampleNormalArea; // xyz: sample normal, w: area of the light
RWTexture2D<float4> gReservoir; // x: weight, y: sum of weights, z: number of candidates M, w: frame number
RWTexture2D<float4> gDiff; // xyz: diffuse BRDF


float4 main(float2 texC : TEXCOORD, float4 pos : SV_Position) : SV_TARGET0
{
	
	uint2 pixel = (uint2)pos.xy;
	
	if(gPosW[pixel].w == 0.0f) {
		// TODO: return environment map
		return float4(0, 0, 0, 1);
	}
	
	float lambert = max(0.0f, dot(gDirToSample[pixel].xyz, gNormW[pixel].xyz));
	return float4(gDiff[pixel].xyz * gEmittedLight[pixel].xyz * lambert * gReservoir[pixel].x, 1.0f);
}
