﻿Shader "Island_Ocean"
{
	Properties
	{
		[Header(Shading)]
		_SunColor 			("Sun Color", Color) 							= ( .5,  .5,  .5,  .5)
		_WaterColor 		("Water Color", Color) 							= (.25, .25, .25, .25)
		_Roughness			("Roughness", Range (0., 1.))					= .35
		_Refractive_Index	("Refractive Index", Range (0., 1.))			= .35
		_Reflection			("Cube Map Reflection", Range (0., 1.))			= .0
		_Haze	 			("Haze", Range (0., 1.)) 						= .01
		_Normal				("Normal Offset", Range (-.5, .5)) 				= .001
		_Waves				("Wave Height", Range (-.5, .5)) 				= .001
	}
	SubShader 
	{
		Tags { "RenderType"="Opaque" }

		Pass
		{ 
			Name "FORWARD" 

			Fog 		{Mode Off}
			Cull 		Back
			ZTest 		Lequal
			Blend 		Off
			ZWrite 		On
			Lighting 	On

			CGPROGRAM
			#pragma vertex vert
			#pragma fragment frag
			#pragma target 2.0
			#include "UnityCG.cginc"

			#define PI (4.*atan(1.))
			#define E	2.7182818

			
			float4 		_SunColor;
			float4 		_WaterColor;
			float		_Refractive_Index;
			float		_Roughness;
			float 		_Haze;
			float 		_Reflection;
			float 		_Depth_Rays;
			float 		_DistanceHaze;
			float		_Waves;
			float 		_Normal;
		

			struct appdata
			{
				float4 vertex	: POSITION;
				float3 normal	: NORMAL;
				float2 uv		: TEXCOORD0;
			};


			struct v2f
			{
				float2 uv				: TEXCOORD0;
				float4 color			: COLOR;
				float4 vertex			: SV_POSITION;
				float4 view				: TEXCOORD1;
				float4 normal			: NORMAL;
			};


			#pragma multi_compile CARDBOARD_DISTORTION 
		 	#include "CardboardDistortion.cginc"
			
			float2 project(float2 position, float2 a, float2 b)
			{
				float2 q	= b - a;	
				float u 	= dot(position - a, q)/dot(q, q);
				u 			= clamp(u, 0., 1.);
				return lerp(a, b, u);
			}

			float projection(float2 position, float2 a, float2 b)
			{
				return distance(position, project(position, a, b));
			}

			float contour(float x, float w)
			{
				return 1.-clamp(dot(x * 2., w), 0., 1.);
			}


			float line_segment(float2 position, float2 a, float2 b, float w)
			{
				return contour(projection(position, a, b), w);	
			}

			float2 hash(float2 uv) 
			{	
				uv	+= sin(uv.yx * 1234.5678);
				return frac(cos(sin(uv + uv.x + uv.y)) * 1234.5678);
			}

			float voronoi(float2 v)
			{
				float2 lattice 	= floor(v);
				float2 field 	= frac(v);
			
				float result = 0.0;
				for(float j = -1.; j <= 1.; j++)
				{
					for(float i = -1.; i <= 1.; i++)
					{
						float2 position	= float2(i, j);
						float2 weight	= position - field + hash(lattice + position);
						float smoothed	= dot(weight, weight) * .5 + .01;

						result			+= 1./pow(smoothed, 8.);
					}
				}
				return clamp(pow(1./result, 1./16.), 0.01, 1.);
			} 


			float2x2 rmat(float theta)
			{
				float c = cos(theta);
				float s = sin(theta);
				return float2x2(c, s, -s, c);
			}


			float map(float3 position)
			{

				float shore				= clamp(pow(abs(length(position+float3(.025, 0., .035))-1.262), 23.), 0., 1.)*.8;

				position.xz				+= float2(8., 5.);

				float time				= _Time.x;
				float2 noise			= (lerp(hash(position.xz), hash(1.+position.xz), cos(_Time.x * -3.16 * 4.)*.5+.5) - .5)*.1;
				float wavesa 			= voronoi(7. + position.xz * -7.92 - time * 8.);

				position.xz				= mul(rmat(wavesa * - .005 + time*.0025), position.xz);

				float wavesb			= voronoi(noise + 5. - position.xz * 32. + time * -9.15) * .32;
			
				float waves				= lerp(wavesa, wavesb, (cos(sin(_Time.x)*wavesa*wavesb)*.5+.5) * (.5-shore*1.+wavesb-noise*shore))-wavesa*.36;

				return clamp(waves, -4., 4.) * _Waves;
			}

	
			float3 map_gradient(float3 position, float delta)
			{
				float3 gradient	= float3(0., 0., 0.);
				float2 offset	= float2(.0, delta);
			
				gradient.x		= map(position + offset.yxx) - map(position - offset.yxx);
				gradient.y		= map(position + offset.xyx) - map(position - offset.xyx);
				gradient.z		= map(position + offset.xxy) - map(position - offset.xxy);

				return gradient;
			} 

			float fresnel(const in float i, float ndv)
			{
				float f = (1.-ndv);
				f = f * f * f * f;
				return i + (1.-i) * f;
			}

			float geometry(in float r, in float ndl, in float ndv)
			{
				float k  = r * r / PI;
				float l = 1./ndl*(1.-k)+k;
				float v = 1./ndv*(1.-k)+k;
				return 1./(l * v + 1e-4f);
			}

			float distribution(const in float r, const in float ndh)
			{ 
				float alpha = r * r;
				float denom = ndh * ndh * (alpha - 1.) + 1.;
				return abs(alpha) / (PI * denom * denom);
			}

			float fog(float depth, float density)
			{	
				return 1./pow(E, depth * density);
			}

			float depth_rays(float3 world_position, float3 view_position, float3 light_direction, float3 normal, float depth) 
			{
				float3 light_position	= cross(_WorldSpaceLightPos0.zyx * float3(-1., -1., 1.), float3(0., 1., 0.));
				
				float2 light_xz			= light_position.xz;
				light_xz				*= depth + depth  - normal.xz;
				
				float2 ray_start		= light_xz + normal.xz - normal.xz * 16.;
				float2 ray_end			= -light_xz-normal.xz/(depth);

				float rays				= clamp(1.-projection(world_position.xz-view_position.xz, ray_start, ray_end)-depth*.125, 0., 1.);
				
				return rays;
			}

			v2f vert (appdata v)
			{
				v2f o;
			
				float3 position			= v.vertex.xyz;
				float waves				= map(position);
				float curvature			= length(position.xz) * 0.185;
				float3 gradient			= map_gradient(position, _Normal);
				float translation		= length(gradient) * 1.5;
				
				gradient.y				= abs(waves) * -.03 + .00625;
				
				float3 normal			= normalize(gradient * float3(-1., 1., -1.));
				
				float cutoff			= length(v.vertex.xz) > .495 ? 0.2 : 1.;


				float shore				= clamp(pow(abs(length(v.vertex.xyz+float3(.05, 0., .035)-waves*2.)-1.179), 24.), 0., 1.)*.8;

				float displacement 		= clamp(waves + waves * abs(shore * 1.625), -1., 1.);
				displacement			+= curvature;
				displacement			*= cutoff;
				displacement			-= .0425;

				v.vertex.y				+= displacement;
				v.vertex.xz				+= normal.xz * translation;

			
				//lighting
				float roughness			= clamp(1.-_Roughness, 0., 1.);
				float index				= clamp(_Refractive_Index, 0., 1.);

				float3 world_position	= mul(unity_ObjectToWorld, v.vertex).xyz;
				float3 view_position	= _WorldSpaceCameraPos.xyz;
				float3 view_direction	= normalize(view_position - world_position);
				float3 light_direction	= -normalize(_WorldSpaceCameraPos.xyz-_WorldSpaceLightPos0.xyz*512.);
				float3 half_direction	= normalize(view_direction + light_direction);

				float light_exposure	= max(dot(normal, light_direction), 0.);
				float view_exposure		= max(dot(normal,  view_direction), 0.);
				float half_exposure		= max(dot(normal,  half_direction), 0.);
				
				float f					= fresnel(roughness, view_exposure);
				float n					= fresnel(f, light_exposure);
				light_exposure			*= n;
				
				float g					= geometry(roughness, light_exposure, view_exposure);
				float d					= distribution(index, half_exposure);
				
				float brdf				= abs(g*d*f)/(view_exposure * light_exposure * 4. + .1);
				brdf 					*= clamp(1.-shore, 0., 1.);
				float depth				= length(view_position - world_position);

				
				float3 light_color		= unity_LightColor[0].xyz;
				
				float surface_scatter	= .0625 + clamp(waves * waves * 256. * depth * _Waves, 0., 1.) * 32.;
				float sub_scatter		= distribution(.95, half_exposure)*(1.-shore);

				float reflection		= clamp(fresnel(.1250-shore,reflect(light_direction, normal)), 0., 1.);

				float density			= _Haze;
				float haze				= pow(1.-fog(depth, density), 15.);
				haze					*= haze * haze * haze + 1.;

				o.color					= float4(0., 0., 0., 0.);
				o.color.xyz				= (light_exposure * _WaterColor.xyz * light_exposure * _SunColor - haze)*.75;
				o.color.xyz				= .85 * lerp(o.color.xyz, float3(1.03, 1., 1.),  clamp(2.*shore * clamp(1./(.35+sub_scatter),.1, 1.),0., .95));
				o.color.xyz				+= surface_scatter * _WaterColor.xyz;		
				o.color.xyz				+=  light_exposure * n * brdf * _SunColor.xyz;
				o.color.xyz				+= sub_scatter * _WaterColor.xyz * light_color * (1.-light_exposure) * 5.;		
				o.color.xyz				+= reflection * float3(.8, .85, .9) * _Reflection;
				o.color.xyz				+= abs(haze);

				o.color.xyz				= pow(o.color.xyz * .925 - clamp(f*.1, .1, .2), 1.39);
				o.color.a				= abs(f*.75+.5);


				o.uv					= v.uv.xy;
				o.normal				= float4(normal, 1.);
				o.view					= float4(view_direction.xyz, 1.);
				o.vertex 				= mul(UNITY_MATRIX_MVP, v.vertex);
				return o;
			}

			fixed4 frag (v2f i) : COLOR
			{
				float2 uv 			= i.uv.xy;
				float4 result		= i.color;				

				return result;
			}
			ENDCG
		}
	}
}