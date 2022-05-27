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
 
__exported import Scene.Shading;
__exported import Utils.Timing.GpuTimer;
__exported import Utils.Math.Ray;
import Utils.Math.MathHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Materials.TexLODTypes;
import Rendering.Materials.TexLODHelpers;
import Rendering.Lights.LightHelpers;
import GBufferHelpers;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerInterface;
import Rendering.Lights.EnvMapSampler;

import Rendering.Materials.IBSDF;

// GBuffer channels
RWTexture2D<float4> gPosW;
RWTexture2D<float4> gNormW;
RWTexture2D<float4> gTangentW;
RWTexture2D<float4> gFaceNormalW;
RWTexture2D<float2> gTexC;
RWTexture2D<float4> gTexGrads;
RWTexture2D<float2> gMotionVector;
RWTexture2D<uint4>  gMaterialData;

// GBufferRT channels
RWTexture2D<PackedHitInfo> gVBuffer;
RWTexture2D<float>  gDepth;
RWTexture2D<float2> gLinearZ;
RWTexture2D<float4> gMotionVectorW;
RWTexture2D<float4> gNormalWRoughnessMaterialID;
RWTexture2D<float4> gDiffOpacity;
RWTexture2D<float4> gSpecRough;
RWTexture2D<float4> gEmissive;
RWTexture2D<float4> gViewW;
RWTexture2D<uint>   gTime;
RWTexture2D<float>  gDisocclusion;

// GBufferRT RIS channels
RWTexture2D<float4> gEmittedLight; // xyz: incoming radiance (y)
RWTexture2D<float4> gDirToSample;  // xyz: direction to light sample, w: distance to the light sample
RWTexture2D<float4> gSampleNormalArea; // xyz: sample normal, w: area of the light
RWTexture2D<float4> gReservoir; // x: weight, y: sum of weights, z: number of candidates M, w: frame number
RWTexture2D<float4> gDiff; // xyz: sample diff BRDF

cbuffer CB {
	uint gCandidateCount;
}

#define is_valid(name) (is_valid_##name != 0)

#if !defined(COMPUTE_DEPTH_OF_FIELD) || !defined(USE_ALPHA_TEST) || !defined(LOD_MODE) || !defined(ADJUST_SHADING_NORMALS) || !defined(RAY_FLAGS)
#error "Not all defines are set!"
#endif


struct GBufferRISRT
{
    static const bool kComputeDepthOfField = COMPUTE_DEPTH_OF_FIELD;
    static const bool kUseAlphaTest = USE_ALPHA_TEST;
    static const TexLODMode kLODMode = TexLODMode(LOD_MODE);
    static const bool kAdjustShadingNormals = ADJUST_SHADING_NORMALS;
    static const uint kRayFlags = RAY_FLAGS;
    static const float kEnvMapDepth = 100000000.0f; // Arbitrary big number

    uint2 frameDim;
    float2 invFrameDim;
    uint frameCount;
    float screenSpacePixelSpreadAngle;
	
	float evalTargetPDF(float3 brdf, float3 Li, float3 lightDir, float3 surfNormal, float lightDist)
	{
		float G = max(dot(lightDir, surfNormal), 0.0f);
		return length(brdf * Li * G);
	}

	void updateReservoir(uint2 launchIndex, float3 Li, float4 dirToSample, float4 sampleNormalArea, float w, inout SampleGenerator sg)
	{
		gReservoir[launchIndex].y += w;
		gReservoir[launchIndex].z += 1.0f;
		
		float weightSum = gReservoir[launchIndex].y;
		
		if (weightSum > 0.0f && sampleNext1D(sg) < (w / weightSum)) 
		{
			gEmittedLight[launchIndex] = float4(Li, 1.0f);
			gDirToSample[launchIndex] = dirToSample;
			gSampleNormalArea[launchIndex] = sampleNormalArea;
		}
	}
	
	//	Streaming RIS using weighted reservoir sampling
	void RIS(const uint2 launchIndex, const uint2 launchDim, const ShadingData sd, const IBSDF bsdf)
	{
		float3 worldPosition = sd.posW;
		float3 worldNormal = normalize(sd.faceN);
		SampleGenerator sg = SampleGenerator(launchIndex, frameCount);
		
		uint lightCount = gScene.getLightCount();
		if (lightCount == 0) return;
		
		// get diffuse BRDF of the hit point material
		BSDFProperties BSDFProp = bsdf.getProperties(sd);
		float3 diffBRDF = BSDFProp.diffuseReflectionAlbedo / M_PI;
		gDiff[launchIndex].xyz = diffBRDF;
		
		for(int i = 0; i < gCandidateCount; i++)
		{
			// Pick one of the analytic light sources randomly with equal probability.
			const uint lightIndex = min(uint(sampleNext1D(sg) * lightCount), lightCount - 1);
			float invp = lightCount;
			const LightData light = gScene.getLight(lightIndex);
			AnalyticLightSample ls;
			if(sampleLight(worldPosition, light, sg, ls))
			{
				float4 sampleNormalArea = float4(ls.normalW, light.surfaceArea); // TODO: get light normal and area for area light
				float4 dirToSample = float4(ls.dir, ls.distance);
				
				float w =  evalTargetPDF(diffBRDF, ls.Li, ls.dir, sd.N, ls.distance) * invp;
				
				updateReservoir(launchIndex, ls.Li, dirToSample, sampleNormalArea, w, sg);
			}
		}

		float targetPDF = evalTargetPDF(diffBRDF, gEmittedLight[launchIndex].xyz, gDirToSample[launchIndex].xyz, sd.N, gDirToSample[launchIndex].w);
		if (targetPDF != 0) {
			gReservoir[launchIndex].x = (gReservoir[launchIndex].y / gReservoir[launchIndex].z) / targetPDF;
		}
		else {
			gReservoir[launchIndex].x = 0;
		}
	}

    /** Ray differentials for primary hit. Code from RayTracingGems, Chapter 20.
    */
    void computeRayDifferentials(const TriangleHit hit, float3 rayDir, float hitT, const Camera camera, float2 invFrameDim, out float2 ddx, out float2 ddy)
    {
        // TODO: Is this code correct for instance transforms that flip the handedness of the coordinate system?

        // Ray differentials
        float3 P[3];
        gScene.getVertexPositionsW(hit.instanceID, hit.primitiveIndex, P);
        float3 e1 = P[1] - P[0];
        float3 e2 = P[2] - P[0];
        float3 d = rayDir;
        float k = dot(cross(e1, e2), d);
        k = abs(k) > 1e-20f ? rcp(k) : 0.0f;
        float3 cu = cross(e2, d);
        float3 cv = cross(d, e1);
        // Assumes a normalized ray direction
        float3 dx = camera.data.cameraU * 2.f * invFrameDim.x / camera.data.focalDistance; // dDdx in ray gen
        float3 dy = camera.data.cameraV * 2.f * invFrameDim.y / camera.data.focalDistance; // dDdy in ray gen
        float3 q = dx * hitT; // Transfer to primary hit
        float3 r = dy * hitT;
        float dudx = k * dot(cu, q);
        float dudy = k * dot(cu, r);
        float dvdx = k * dot(cv, q);
        float dvdy = k * dot(cv, r);
        float2 T[3];
        gScene.getVertexTexCoords(hit.instanceID, hit.primitiveIndex, T);
        float2 g1 = T[1] - T[0];
        float2 g2 = T[2] - T[0];
        float dsdx = (dudx * g1.x + dvdx * g2.x);
        float dsdy = (dudy * g1.x + dvdy * g2.x);
        float dtdx = (dudx * g1.y + dvdx * g2.y);
        float dtdy = (dudy * g1.y + dvdy * g2.y);
        ddx = float2(dsdx, dtdx);
        ddy = float2(dsdy, dtdy);
    }

    void computeAnisotropicAxesRayCones(const TriangleHit hit, VertexData v, float3 rayDir, float hitT, float pixelAngle, out float2 ddx, out float2 ddy)
    {
        float3 positions[3];
        float2 texCoords[3];
        gScene.getVertexPositionsW(hit.instanceID, hit.primitiveIndex, positions);
        gScene.getVertexTexCoords(hit.instanceID, hit.primitiveIndex, texCoords);

        float coneWidthAtHitPoint = hitT * tan(pixelAngle);   // The exact expression is 2.0f * hitT * tan(pixelAngle * 0.5f), but can be approximated as hitT * tan(pixelAngle) due to tan(b) ~= b for small b.
        // Using faceNormal, since it is needed for the barycentric computations inside computeAnisotropicEllipseAxes().
        computeAnisotropicEllipseAxes(v.posW, v.faceNormalW, rayDir, coneWidthAtHitPoint, positions, texCoords, v.texC, ddx, ddy);
    }

    float3 computeDdxPosW(float3 posW, float3 normW, float2 invFrameDim)
    {
        float3 projRight = normalize(cross(normW, cross(normW, gScene.camera.data.cameraV)));
        float distanceToHit = length(posW - gScene.camera.data.posW);
        float2 ddNdc = float2(2.f, -2.f) * invFrameDim;
        float distRight = distanceToHit * ddNdc.x / dot(normalize(gScene.camera.data.cameraV), projRight);
        return distRight * projRight;
    }

    float3 computeDdyPosW(float3 posW, float3 normW, float2 invFrameDim)
    {
        float3 projUp = normalize(cross(normW, cross(normW, gScene.camera.data.cameraU)));
        float distanceToHit = length(posW - gScene.camera.data.posW);
        float2 ddNdc = float2(2.f, -2.f) * invFrameDim;
        float distUp = distanceToHit * ddNdc.y / dot(normalize(gScene.camera.data.cameraU), projUp);
        return distUp * projUp;
    }

    Ray generateRay(uint2 pixel)
    {
        if (kComputeDepthOfField)
        {
            SampleGenerator sg = SampleGenerator(pixel, frameCount);
            return gScene.camera.computeRayThinlens(pixel, frameDim, sampleNext2D(sg));
        }
        else
        {
            return gScene.camera.computeRayPinhole(pixel, frameDim);
        }
    }

    void writeHit(uint2 pixel, uint2 dim, float3 rayOrigin, float3 rayDir, const HitInfo hit, float hitT)
    {
        uint materialID = 0;
        VertexData v = {};
        float curveRadius = 0.f;
        float3 prevPosW = {};
        float4 texGrads = {};
        float2 motionVector = {};
        float4 motionVectorW = {};
        float disocclusion = 0.f;
        ITextureSampler lod = ExplicitLodTextureSampler(0.f); // The default LOD method is replaced below in some cases.

        // Compute data at the hit.
        if (hit.getType() == HitType::Triangle)
        {
            const TriangleHit triangleHit = hit.getTriangleHit();

            materialID = gScene.getMaterialID(triangleHit.instanceID);
            v = gScene.getVertexData(triangleHit);
            prevPosW = gScene.getPrevPosW(triangleHit);

            if (kLODMode == TexLODMode::RayCones)
            {
                float2 ddx, ddy;
                computeAnisotropicAxesRayCones(triangleHit, v, rayDir, hitT, screenSpacePixelSpreadAngle, ddx, ddy);
                lod = ExplicitGradientTextureSampler(ddx, ddy);
                texGrads = float4(ddx, ddy);
            }
            else if (kLODMode == TexLODMode::RayDiffs)
            {
                float2 ddx, ddy;
                computeRayDifferentials(triangleHit, rayDir, hitT, gScene.camera, invFrameDim, ddx, ddy);
                lod = ExplicitGradientTextureSampler(ddx, ddy);
                texGrads = float4(ddx, ddy);
            }
            // else kLODMode == TexLODMode::Mip0
        }
        else if (hit.getType() == HitType::DisplacedTriangle)
        {
            const DisplacedTriangleHit displacedTriangleHit = hit.getDisplacedTriangleHit();

            materialID = gScene.getMaterialID(displacedTriangleHit.instanceID);
            v = gScene.getVertexData(displacedTriangleHit, -rayDir);
            prevPosW = gScene.getPrevPosW(displacedTriangleHit);
        }
        else if (hit.getType() == HitType::Curve)
        {
            const CurveHit curveHit = hit.getCurveHit();

            materialID = gScene.getMaterialID(curveHit.instanceID);
            v = gScene.getVertexDataFromCurve(curveHit, curveRadius);
            prevPosW = gScene.getPrevPosWFromCurve(curveHit);
        }
        else if (hit.getType() == HitType::SDFGrid)
        {
            const SDFGridHit sdfGridHit = hit.getSDFGridHit();

            materialID = gScene.getMaterialID(sdfGridHit.instanceID);
            v = gScene.getVertexDataFromSDFGrid(sdfGridHit, rayOrigin, rayDir);
            prevPosW = gScene.getPrevPosWFromSDFGrid(sdfGridHit, v.posW);
        }
        else
        {
            // We hit some other geometry type that isn't supported. This shouldn't happen but
            // early out here just in case to avoid crash below if trying to setup an invalid material.
            return;
        }

        // Prepare shading data.
        ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -rayDir, lod);

        if (kAdjustShadingNormals && (hit.getType() == HitType::Triangle || hit.getType() == HitType::DisplacedTriangle))
        {
            adjustShadingNormal(sd, v);
        }

        if (hit.getType() == HitType::Triangle || hit.getType() == HitType::DisplacedTriangle || hit.getType() == HitType::Curve || hit.getType() == HitType::SDFGrid)
        {
            // Compute motion vector in screen and world space.
            float2 pixelPos = pixel + float2(0.5f, 0.5f);
            float4 prevPosH = mul(float4(prevPosW, 1.f), gScene.camera.data.prevViewProjMatNoJitter);
            motionVector = calcMotionVector(pixelPos, prevPosH, frameDim) + float2(gScene.camera.data.jitterX, -gScene.camera.data.jitterY); // Remove camera jitter from motion vector
            motionVectorW = float4(prevPosW - sd.posW, 0.f);

            // Compute disocclusion.
            // Do the occlusion masking in linearZ space
            float4 curPosH = mul(float4(sd.posW, 1.f), gScene.camera.data.viewProjMatNoJitter);
            disocclusion = prevPosH.w - curPosH.w;
        }

        // Create BSDF instance.
        let bsdf = gScene.materials.getBSDF(sd, lod);

        const GBufferData gbuf = prepareGBufferData(sd, bsdf);

        if (hit.getType() == HitType::Curve) gbuf.posW.w = curveRadius;
		

		
        // GBuffer channels
        if (is_valid(gPosW))                gPosW[pixel]                = gbuf.posW;
        if (is_valid(gNormW)) {
			float depth = length(gScene.camera.data.posW - sd.posW);
			gNormW[pixel].xyz   = gbuf.normW.xyz;
			gNormW[pixel].w = depth;
		}
        if (is_valid(gTangentW))            gTangentW[pixel]            = gbuf.tangentW;
        if (is_valid(gFaceNormalW))         gFaceNormalW[pixel]         = gbuf.faceNormalW;
        if (is_valid(gTexC))                gTexC[pixel]                = gbuf.texC;
        if (is_valid(gTexGrads))            gTexGrads[pixel]            = texGrads;
        if (is_valid(gMotionVector))        gMotionVector[pixel]        = motionVector;
        if (is_valid(gMaterialData))        gMaterialData[pixel]        = gbuf.mtlData;

        // GBufferRT channels
        if (is_valid(gMotionVectorW))       gMotionVectorW[pixel]       = motionVectorW;
        if (is_valid(gDiffOpacity))         gDiffOpacity[pixel]         = gbuf.diffuseOpacity;
        if (is_valid(gSpecRough))           gSpecRough[pixel]           = gbuf.specRough;
        if (is_valid(gEmissive))            gEmissive[pixel]            = gbuf.emissive;
        if (is_valid(gDisocclusion))        gDisocclusion[pixel]        = disocclusion;

        if (is_valid(gLinearZ))
        {
            // TODO: Improve computation of derivatives:
			float4 curPosH = mul(float4(sd.posW, 1.f), gScene.camera.data.viewProjMatNoJitter);
			float curLinearZ = curPosH.w;
            float3 ddxPosW = computeDdxPosW(sd.posW, sd.faceN, invFrameDim);
            float3 ddyPosW = computeDdyPosW(sd.posW, sd.faceN, invFrameDim);
            float4 curPosH_dx = mul(float4(sd.posW + ddxPosW, 1.f), gScene.camera.data.viewProjMatNoJitter);
            float4 curPosH_dy = mul(float4(sd.posW + ddxPosW, 1.f), gScene.camera.data.viewProjMatNoJitter);
            float ddxLinearZ = abs(curPosH_dx.w - curLinearZ);
            float ddyLinearZ = abs(curPosH_dy.w - curLinearZ);
            float dLinearZ = max(ddxLinearZ, ddyLinearZ);
            gLinearZ[pixel] = float2(curLinearZ, dLinearZ);
        }

        // Output a depth buffer similar to raster (NDC).
        if (is_valid(gDepth))
        {
            float4 curPosH = mul(float4(sd.posW, 1.f), gScene.camera.data.viewProjMatNoJitter);
            gDepth[pixel] = curPosH.z / curPosH.w;
        }

        // Output a buffer that packs normal and roughness estimation.
        if (is_valid(gNormalWRoughnessMaterialID))
        {
            float2 octNormal = ndir_to_oct_unorm(sd.N);
            float roughness = bsdf.getProperties(sd).roughness;
            float materialID = 0.f;
            gNormalWRoughnessMaterialID[pixel] = float4(octNormal, roughness, materialID);
        }

        // Encode hit information.
        if (is_valid(gVBuffer))
        {
            gVBuffer[pixel] = hit.getData();
        }
		
		// Streaming RIS using reservoir sampling
		RIS(pixel, dim, sd, bsdf);
		
    }

    float2 computeMotionVectorBackground(const uint2 pixel, const float3 rayOrigin, const float3 rayDir)
    {
        // Hacky motion vector computation for env map, taking the camera movement into account
        float3 worldPos = rayOrigin + normalize(rayDir) * kEnvMapDepth; // Hit on env map

        float2 pixelPos = pixel + float2(0.5f, 0.5f);
        float4 prevPosH = mul(float4(worldPos, 1.f), gScene.camera.data.prevViewProjMatNoJitter);
        return calcMotionVector(pixelPos, prevPosH, frameDim) + float2(gScene.camera.data.jitterX, -gScene.camera.data.jitterY); // Remove camera jitter from motion vector
    }

    void writeMiss(const uint2 pixel, const float3 rayOrigin, const float3 rayDir)
    {
        const float2 mvec = computeMotionVectorBackground(pixel, rayOrigin, rayDir);
        const float2 octNormal = ndir_to_oct_unorm(float3(0.2215f, 0.2215f, 0.2215f)); // UE4 default value at miss
        const float roughness = 0.f;
        const float materialID = 0.f;

        // GBuffer channels
        if (is_valid(gPosW))                        gPosW[pixel]                        = {};
        if (is_valid(gNormW))                       gNormW[pixel]                       = {};
        if (is_valid(gTangentW))                    gTangentW[pixel]                    = {};
        if (is_valid(gFaceNormalW))                 gFaceNormalW[pixel]                 = {};
        if (is_valid(gTexC))                        gTexC[pixel]                        = {};
        if (is_valid(gTexGrads))                    gTexGrads[pixel]                    = {};
        if (is_valid(gMotionVector))                gMotionVector[pixel]                = mvec;

        // GBufferRT channels
        if (is_valid(gVBuffer))                     gVBuffer[pixel]                     = {};
        if (is_valid(gDepth))                       gDepth[pixel]                       = 1.f;
        if (is_valid(gLinearZ))                     gLinearZ[pixel]                     = float2(kEnvMapDepth, 0.f);
        if (is_valid(gMotionVectorW))               gMotionVectorW[pixel]               = {};
        if (is_valid(gNormalWRoughnessMaterialID))  gNormalWRoughnessMaterialID[pixel]  = float4(octNormal, roughness, materialID);
        if (is_valid(gDiffOpacity))                 gDiffOpacity[pixel]                 = {};
        if (is_valid(gSpecRough))                   gSpecRough[pixel]                   = {};
        if (is_valid(gEmissive))                    gEmissive[pixel]                    = {};
        if (is_valid(gDisocclusion))                gDisocclusion[pixel]                = 0.f;
    }

    void writeAux(uint2 pixel, const Ray ray)
    {
        // Write view direction.
        if (is_valid(gViewW)) gViewW[pixel] = float4(-ray.dir, 0.f);
    }

    void beginTime(inout GpuTimer timer)
    {
        if (is_valid(gTime)) timer.start();
    }

    void endTime(uint2 pixel, inout GpuTimer timer)
    {
        if (is_valid(gTime)) gTime[pixel] = timer.getElapsed();
    }
};
