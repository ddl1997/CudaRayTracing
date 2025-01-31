#define TINYOBJLOADER_IMPLEMENTATION
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "Global.h"
#include "Loader.h"
#include "Object.h"
#include "Scene.h"
#include <glad/glad.h>
#include "Render.cuh"
#include "Camera.h"
#include "Eigen/Dense"
#include "Eigen/Core"
#include "Gui.h"
#include <vector>
#include <iostream>
#include <fstream>
#include <sstream>
#include <filesystem>
#include <GLFW/glfw3.h>
#include <chrono>
#include <thread>
#include <json.hpp>
#include <cuda_gl_interop.h>
#include <imgui.h>
#include <imgui_impl_glfw.h>
#include <imgui_impl_opengl3.h>

// ======================================================================================
// A binary tree contains nodes with degree = 0 or 2, satisfies:
// 2 * y = x + y + 1,  ( x, y denote the number of nodes with degree = 0, degree = 2 )
// then, y = x + 1.
// Meanwhile, x = ceil(triangles_n / bvh_thresh_n), 
// thus, bvh_nodes_n = x + y = 2 * x + 1.
// Consequently, bvh_nodes_n = 2 * ceil(triangles_n / bvh_thresh_n) + 1.
// If we set the bvh_nodes_n, it can be worked out that:
// bvh_thresh_n = triangles_n / [(bvh_nodes_n - 1) / 2 - 1]
// ======================================================================================


using json = nlohmann::json;
struct Task {
    std::vector<std::pair<std::string, std::string>> OBJ_paths;
    Eigen::Vector3f lookat;
    Eigen::Vector3f up;
    Eigen::Vector3f eye_pos;
    float ar;
    float fov_y;
    float far;
    float near;
    unsigned int width;
    unsigned int height;
    unsigned int bvh_thresh_n;
    unsigned int light_sample_n;
    float P_RR;
    unsigned int spp;

};


Task task;

#ifdef _MSC_VER
std::string config_path("../../config.json");
#else
std::string config_path("../config.json");
#endif

bool config_task()
{
    std::ifstream json_file(config_path);
    std::stringstream json_data;
    json_data << json_file.rdbuf();
    json task_json = json::parse(json_data);

    for (const auto& path_json : task_json["OBJ_paths"])
    {
        task.OBJ_paths.push_back({path_json["OBJ_path"], path_json["MTL_dir"]});
    }
    task.eye_pos = Eigen::Vector3f(task_json["eye_pos"]["x"], task_json["eye_pos"]["y"], task_json["eye_pos"]["z"]);
    task.lookat = Eigen::Vector3f(task_json["lookat"]["x"], task_json["lookat"]["y"], task_json["lookat"]["z"]);
    task.up = Eigen::Vector3f(task_json["up"]["x"], task_json["up"]["y"], task_json["up"]["z"]);
    task.fov_y = task_json["fov_y"];
    task.width = task_json["width"];
    task.height = task_json["height"];
    task.bvh_thresh_n = task_json["bvh_thresh_n"];
    task.P_RR = task_json["P_RR"];
    task.spp = task_json["spp"];
    task.light_sample_n = task_json["light_sample_n"];

    return true;
}

bool config_CUDA()
{
    cudaDeviceProp deviceProp;
    int deviceCount;
    cudaGetDeviceCount(&deviceCount);
    if(deviceCount > 0)
    {
        cudaGetDeviceProperties(&deviceProp, 0);
        cudaSetDevice(0);
        return true;
    }
    printf("Failed to find CUDA device\n");
    return false;
}

std::string getCurrentTimeString()
{
    auto now = std::chrono::system_clock::now();
    auto time = std::chrono::system_clock::to_time_t(now);
    std::tm bt = *std::localtime(&time);

    std::ostringstream oss;
    oss << std::put_time(&bt, "%Y-%m-%d-%H-%M-%S");

    return oss.str();
}

void render_view()
{
    Scene scene(task.width, task.height);
    for(const auto& OBJ_path : task.OBJ_paths)
    {
        Loader loader;
        std::vector<Triangle> triangles;
        std::vector<Triangle> light_triangles;
        triangles.clear();
        light_triangles.clear();
        loader.read_OBJ(OBJ_path.first.c_str(), OBJ_path.second.c_str());
        printf("size=%llu\n", loader.size());
        for (uint64_t i = 0; i < loader.size(); i++)
        {
            loader.load_object(i, triangles, light_triangles);
            if (triangles.size() > 0)
            {
                printf("normal\n");
                scene.add_normal_obj(Object(triangles));
            }
            if (light_triangles.size() > 0)
            {
                printf("light\n");
                scene.add_light_obj(Object(light_triangles));
            }
        }
    }
    printf("here\n");
    // configure opengl
    glfwInit();
    glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3);
    glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 3);
    glfwWindowHint(GLFW_OPENGL_PROFILE, GLFW_OPENGL_CORE_PROFILE);

    GLFWwindow* window = glfwCreateWindow(800, 600, "CudaRayTracing", NULL, NULL);
    if (window == NULL)
    {
        std::cout << "Failed to create GLFW window" << std::endl;
        glfwTerminate();
        return ;
    }
    glfwMakeContextCurrent(window);

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO(); (void)io;
    ImGui::StyleColorsDark();
    ImGui_ImplGlfw_InitForOpenGL(window, true);
    ImGui_ImplOpenGL3_Init("#version 330");

    if (!gladLoadGLLoader((GLADloadproc)glfwGetProcAddress))
    {
        std::cout << "Failed to initialize GLAD" << std::endl;
        return ;
    }

    glViewport(0, 300, 800, 600);

    GLuint pbo;
    glGenBuffers(1, &pbo);
    glBindBuffer(GL_PIXEL_UNPACK_BUFFER, pbo);
    glBufferData(GL_PIXEL_UNPACK_BUFFER, task.width * task.height * 3, 0, GL_STREAM_DRAW);
    glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);

    GLuint textureID;
    glGenTextures(1, &textureID);
    glBindTexture(GL_TEXTURE_2D, textureID);
    
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, task.width, task.height, 0, GL_RGB, GL_UNSIGNED_BYTE, 0);
    glGenerateMipmap(GL_TEXTURE_2D);

    glBindTexture(GL_TEXTURE_2D, 0);


    float vertices[] = {
        // positions        // texture coords
        -1.0f, -1.0f, 0.0f, 0.0f, 0.0f, // bottom left
         1.0f, -1.0f, 0.0f, 1.0f, 0.0f, // bottom right
         1.0f,  1.0f, 0.0f, 1.0f, 1.0f, // top right

        -1.0f, -1.0f, 0.0f, 0.0f, 0.0f, // bottom left
         1.0f,  1.0f, 0.0f, 1.0f, 1.0f, // top right
        -1.0f,  1.0f, 0.0f, 0.0f, 1.0f  // top left
    };

    GLuint VAO, VBO;
    glGenVertexArrays(1, &VAO);
    glGenBuffers(1, &VBO);

    glBindVertexArray(VAO);

    glBindBuffer(GL_ARRAY_BUFFER, VBO);
    glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);

    // position attribute
    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 5 * sizeof(float), (void*)0);
    glEnableVertexAttribArray(0);
    
    // texture coord attribute
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 5 * sizeof(float), (void*)(3 * sizeof(float)));
    glEnableVertexAttribArray(1);

    const char *vertexShaderSource = R"glsl(
        #version 330 core
        layout (location = 0) in vec3 aPos;
        layout (location = 1) in vec2 aTexCoord;

        out vec2 TexCoord;

        void main()
        {
            gl_Position = vec4(aPos, 1.0);
            TexCoord = vec2(aTexCoord.x, 1.0 - aTexCoord.y);
        })glsl";

    const char *fragmentShaderSource = R"glsl(
        #version 330 core
        out vec4 FragColor;

        in vec2 TexCoord;

        uniform sampler2D texture1;

        void main()
        {
            FragColor = texture(texture1, TexCoord);
        })glsl";

    GLint vs_id = glCreateShader(GL_VERTEX_SHADER);
    GLint fs_id = glCreateShader(GL_FRAGMENT_SHADER);
    glShaderSource(vs_id, 1, &vertexShaderSource, nullptr);
    glShaderSource(fs_id, 1, &fragmentShaderSource, nullptr);
    
    GLint prog_id = glCreateProgram();
    
    glCompileShader(vs_id);
    glCompileShader(fs_id);
    
    glAttachShader(prog_id, vs_id);
    glAttachShader(prog_id, fs_id);
    
    glLinkProgram(prog_id);
    glValidateProgram(prog_id);

    glDeleteShader(vs_id);
    glDeleteShader(fs_id);

    glUseProgram(prog_id);

    cudaGraphicsResource* cuda_pbo_resource;
    cudaGraphicsGLRegisterBuffer(&cuda_pbo_resource, pbo, cudaGraphicsMapFlagsWriteDiscard);

    scene.set_BVH(task.bvh_thresh_n);
    printf("BVH built.\n");
    float fov_y = task.fov_y * (float)M_PI / 180;
    bool rendered = false;
    bool clicked = false;
    Gui gui(task.height, task.width, task.eye_pos.data(), task.lookat.data(), task.up.data(), task.P_RR, task.spp, task.light_sample_n);
    Render render(&scene, gui.get_spp(), gui.get_P_RR(), gui.get_light_sample_n());
    glUseProgram(prog_id);

    while(!glfwWindowShouldClose(window))
    {
        glfwPollEvents();
        ImGui_ImplOpenGL3_NewFrame();
        ImGui_ImplGlfw_NewFrame();
        ImGui::NewFrame();

        ImGui::Begin("CudaRayTracing");

        if (ImGui::TreeNode("View"))
        {
            if (ImGui::InputFloat3("Eye position", gui.eye_pos()))
            {
                std::cout << "Update eye position: (" << gui.eye_pos()[0] << ", " << gui.eye_pos()[1] << ", " << gui.eye_pos()[2] << ")" << std::endl;
            }
            
            if (ImGui::InputFloat3("Lookat position", gui.lookat()))
            {
                std::cout << "Update lookat position: (" << gui.lookat()[0] << ", " << gui.lookat()[1] << ", " << gui.lookat()[2] << ")" << std::endl;
            }
            
            if (ImGui::InputFloat3("Up vector", gui.up()))
            {
                std::cout << "Update up vector: (" << gui.up()[0] << ", " << gui.up()[1] << ", " << gui.up()[2] << ")" << std::endl;
            }
            ImGui::TreePop();
        }

        // if (ImGui::SliderInt("Height", gui.height(), 256, 2560))
        // {
        //     std::cout << "Update height: " << gui.get_height() << std::endl;
        //     render.set_height(static_cast<unsigned int>(gui.get_height()));
        // }

        // if (ImGui::SliderInt("Width", gui.width(), 256, 2560))
        // {
        //     std::cout << "Update width: " << gui.get_width() << std::endl;
        //     render.set_height(static_cast<unsigned int>(gui.get_width()));
        // }

        if (ImGui::SliderInt("Samples per Pixel (spp)", gui.spp(), 1, 2048))
        {
            std::cout << "Update spp value: " << gui.get_spp() << std::endl;
            render.set_spp(gui.get_spp());
        }

        if (ImGui::SliderFloat("Russian Roulette Probability (P_RR)", gui.P_RR(), 0.0f, 1.0f))
        {
            std::cout << "Update P_RR value: " << gui.get_P_RR() << std::endl;
            render.set_P_RR(gui.get_P_RR());
        }

        if (ImGui::SliderInt("Light Samples (light_sample_n)", gui.light_sample_n(), 1, 64))
        {
            std::cout << "Update light_sample_n value: " << gui.get_light_sample_n() << std::endl;
            render.set_light_sample_n(gui.get_light_sample_n());
        }

        if (ImGui::Button("Render"))
        {
            clicked = true;
            rendered = true;
        }
        else
        {
            clicked = false;
        }
        ImGui::SameLine();
        if (ImGui::Button("Save"))
        {
            namespace fs = std::filesystem;
            std::string save_path(".tmp/");
            save_path.append(getCurrentTimeString().append(".png"));
            fs::path path_to_file(save_path);
            if (!fs::exists(path_to_file.parent_path()))
            {
                fs::create_directories(path_to_file.parent_path());
            }
            render.save_frame_buffer(save_path.c_str());
        }
        ImGui::End();
        ImGui::Render();
        ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());
        if (clicked)
        {
            auto begin = std::chrono::high_resolution_clock::now();
            auto inv_view_mat = get_inverse_view_matrix(gui.get_eye_pos_vec(), gui.get_lookat_vec(), gui.get_up_vec());
            render.run_view(gui.get_eye_pos_vec(), inv_view_mat, fov_y, cuda_pbo_resource);

            auto end = std::chrono::high_resolution_clock::now();
            std::chrono::duration<double> elapsed = end - begin;
            std::cout << "render cost: " << elapsed.count() << " seconds" << std::endl;
        }
        if (rendered)
        {
            glBindTexture(GL_TEXTURE_2D, textureID);
            glBindBuffer(GL_PIXEL_UNPACK_BUFFER, pbo);
            glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, task.width, task.height, GL_RGB, GL_UNSIGNED_BYTE, 0);
            glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
            glBindTexture(GL_TEXTURE_2D, 0);
            glBindVertexArray(VAO);
            glBindTexture(GL_TEXTURE_2D, textureID);
            glDrawArrays(GL_TRIANGLES, 0, 6);
            glBindTexture(GL_TEXTURE_2D, 0);
        }
        glfwSwapBuffers(window);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    }
    
    render.free();
    scene.free();
    glDeleteVertexArrays(1, &VAO);
    glDeleteBuffers(1, &VBO);
    cudaGraphicsUnregisterResource(cuda_pbo_resource);
    glDeleteBuffers(1, &pbo);
    glDeleteTextures(1, &textureID);

    ImGui_ImplOpenGL3_Shutdown();
    ImGui_ImplGlfw_Shutdown();
    ImGui::DestroyContext();
    glfwDestroyWindow(window);
    glfwTerminate();
}



int main(void)
{
    if(!config_CUDA())
    {
        printf("Failed to configure CUDA\n");
        return -1;
    }
    if(!config_task())
    {
        return -1;
    }
    
    render_view();

    return 0;
}